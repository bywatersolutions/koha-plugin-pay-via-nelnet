package Koha::Plugin::Com::ByWaterSolutions::PayViaNelnet;

use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth qw(get_template_and_user);
use Koha::Account;
use Koha::Account::Lines;
use List::Util qw(sum);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode_utf8 encode_utf8);
use Time::HiRes qw(gettimeofday);
use Try::Tiny;

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name          => 'Pay Via Nelnet',
    author        => 'Kyle M Hall',
    description   => 'This plugin enables online OPAC fee payments via Nelnet',
    date_authored => '2020-04-14',
    date_updated  => '1900-01-01',
    minimum_version => '19.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
};

our $ENABLE_DEBUGGING = 1;

# Encrypted credentials are stored with this marker in front of the ciphertext so we can
# tell them apart from cleartext values left behind by versions before encryption existed.
our $ENCRYPTION_PREFIX = 'koha-enc-v1:';

# The stored configuration keys holding secrets, which must be encrypted at rest
our @CREDENTIAL_KEYS = qw( key );

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my @accountline_ids = $cgi->multi_param('accountline');

    my $rs = Koha::Database->new()->schema()->resultset('Accountline');
    my @accountlines = map { $rs->find($_) } @accountline_ids;

    my $patron = scalar Koha::Patrons->find($borrowernumber);

    my $token = "B" . $borrowernumber . "T" . time;
    C4::Context->dbh->do(
        q{
        INSERT INTO nelnet_plugin_tokens ( token, borrowernumber )
        VALUES ( ?, ? )
    }, undef, $token, $borrowernumber
    );

    my $amount = sprintf("%.2f", sum( map { $_->amountoutstanding } @accountlines ) );
    $amount =~ s/\.//; # Amount should be formatted as cents, e.g. $1.99 => 199

    my $redirect_url = C4::Context->preference('OPACBaseURL') . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::ByWaterSolutions::PayViaNelnet";
    my $redirectUrlParameters = "transactionType,transactionStatus,transactionId,transactionResultCode,transactionResultMessage,orderAmount,userChoice1,userChoice2,userChoice3";

    my $url_params = [];
    $url_params->[0] = { key => 'orderType', val => $self->retrieve_data('order_type')};
    $url_params->[1] = { key => 'orderNumber', val => $accountlines[0]->id};
    $url_params->[2] = { key => 'orderName', val => $patron->firstname . $patron->surname};
    $url_params->[3] = { key => 'orderDescription', val => "Payment of library fees"};
    $url_params->[4] = { key => 'amount', val => $amount };
    $url_params->[5] = { key => 'userChoice1', val => $patron->id }; # Borrowernumber for verification
    $url_params->[6] = { key => 'userChoice2', val => join( ',', map { $_->id } @accountlines ) }; # Accountlines to pay
    $url_params->[7] = { key => 'userChoice3', val => $token }; # Token we generate to avoid duplicate or false payments in Koha
    $url_params->[8] = { key => 'redirectUrl', val => $redirect_url };
    $url_params->[9] = { key => 'redirectUrlParameters', val => $redirectUrlParameters };
    $url_params->[10] = { key => 'retriesAllowed', val => 1};
    $url_params->[11] = { key => 'timestamp', val => int (gettimeofday * 1000)}; # Epoch time in milliseconds

    # The shared secret is the final element of the hash input per Nelnet's Commerce
    # Manager specification, but must never be transmitted - the specification's
    # parameter table marks it "Passed to QuikPAY: No", and Commerce Manager validates
    # the hash using its own stored copy of the key. Appending it here produces the
    # exact hash this plugin has always computed, since the key used to be the last
    # element of the array being joined.
    my $combined_url_values = join( '', map { $_->{val}} @$url_params );
    my $sha256 = sha256_hex( $combined_url_values . $self->_get_secret('key') );

    my @params;
    
    foreach my $elt ( @$url_params ) {
        my $key = $elt->{key};
        my $value = $elt->{val}; #= $uri->encode( $elt->{val} );
        push( @params, "$key=$value" );
    }
    my $combined_params = join( '&', @params );
    $combined_params .= "&hash=$sha256";

    $template->param(
        borrower             => $patron,
        payment_method       => scalar $cgi->param('payment_method'),
        enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
        accountlines         => \@accountlines,
        url                  => $self->retrieve_data('url'),
        url_params           => $url_params,
        url_combined_params  => $combined_params,
    );

    print $cgi->header();
    print $template->output();
}

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $logged_in_borrowernumber ) = get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );
    my %vars = $cgi->Vars();
    #warn "NELNET INCOMING: " . Data::Dumper::Dumper( \%vars );

    my $borrowernumber = $vars{userChoice1};
    my $accountline_ids = $vars{userChoice2};
    my $token = $vars{userChoice3};

    my $transaction_status = $vars{transactionStatus};
    my $transaction_id = $vars{transactionId};
    my $transaction_result_message = $vars{transactionResultMessage};
    my $order_amount = sprintf("%.2f", $vars{orderAmount} / 100 );

    my $dbh      = C4::Context->dbh;
    my $query    = "SELECT * FROM nelnet_plugin_tokens WHERE token = ?";
    my $token_hr = $dbh->selectrow_hashref( $query, undef, $token );

    my $accountlines = [ split( ',', $accountline_ids ) ];

    my ( $m, $v );
    if ( $logged_in_borrowernumber ne $borrowernumber ) {
        $m = 'not_same_patron';
        $v = $transaction_id;
    }
    elsif ( $transaction_status eq '1' ) { # Success
        if ($token_hr) {
            my $note = "Paid via NelNet: " . sha256_hex( $transaction_id );

            # If this note is found, it must be a duplicate post
            unless (
                Koha::Account::Lines->search( { note => $note } )->count() )
            {

                my $patron  = Koha::Patrons->find($borrowernumber);
                my $account = $patron->account;

                my $schema = Koha::Database->new->schema;

                my @lines = Koha::Account::Lines->search( { accountlines_id => { -in => $accountlines } } )->as_list;

                $schema->txn_do(
                    sub {
                        $dbh->do(
                            "DELETE FROM nelnet_plugin_tokens WHERE token = ?",
                            undef, $token
                        );

                        $account->pay(
                            {
                                amount     => $order_amount,
                                note       => $note,
                                library_id => $patron->branchcode,
                                lines      => \@lines,
                            }
                        );
                    }
                );

                $m = 'valid_payment';
                $v = $order_amount;
            }
            else {
                $m = 'duplicate_payment';
                $v = $transaction_id;
            }
        }
        else {
            $m = 'invalid_token';
            $v = $transaction_id;
        }
    }
    else {
        # 1 = Accepted credit card payment/refund (successful)
        # 2 = Rejected credit card payment/refund (declined)
        # 3 - Error credit card payment/refund (error)
        $m = 'payment_failed';
        $v = $transaction_id;
    }

    $template->param(
        borrower      => scalar Koha::Patrons->find($borrowernumber),
        message       => $m,
        message_value => $v,
    );

    print $cgi->header();
    print $template->output();
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    # An instance that had no encryption key when the plugin was upgraded still holds its
    # credentials in cleartext, so try again every time someone opens the configuration page
    $self->_encrypt_stored_credentials;

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        my $stored_key = $self->retrieve_data('key');

        ## Grab the values we already have for our settings, if any exist
        ## The shared secret itself is deliberately never sent to the template
        $template->param(
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            url => $self->retrieve_data('url'),
            orderType => $self->retrieve_data('order_type'),
            key_is_set => ( defined $stored_key && length $stored_key ) ? 1 : 0,
            key_is_encrypted =>
                ( $stored_key && index( $stored_key, $ENCRYPTION_PREFIX ) == 0 ) ? 1 : 0,
            encryption_available => $self->_encryption ? 1 : 0,
            csrf_token           => $self->_csrf_token,
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        # An empty key field means "keep the current key", so _set_secret ignores it
        $self->_set_secret( 'key', scalar $cgi->param('key') );

        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                order_type        => $cgi->param('orderType'),
                url => $cgi->param('url'),
            }
        );
        $self->go_home();
    }
}

=head3 _encryption

    my $encryption = $self->_encryption;

Returns a Koha::Encryption object, or undef when encryption is unavailable. It is unavailable
on Koha before 22.05, and on any instance where encryption_key is unset in koha-conf.xml.

=cut

sub _encryption {
    my ($self) = @_;

    return try {
        require Koha::Encryption;
        Koha::Encryption->new;
    } catch {
        undef;
    };
}

=head3 _csrf_token

    my $token = $self->_csrf_token;

Returns a CSRF token for the configuration form, or undef on Koha versions that have no
Koha::Token. Koha::Middleware::CSRF answers any tokenless POST to the staff interface with
a 403, so the configuration form cannot be submitted without this.

=cut

sub _csrf_token {
    my ($self) = @_;

    return try {
        require Koha::Token;
        Koha::Token->new->generate_csrf( { session_id => scalar $self->{'cgi'}->cookie('CGISESSID') } );
    } catch {
        undef;
    };
}

=head3 _get_secret

    my $key = $self->_get_secret('key');

Returns the cleartext value of a stored credential. Values stored before encryption was added
carry no prefix and are returned as-is, so an instance without an encryption key keeps working.

=cut

sub _get_secret {
    my ( $self, $key ) = @_;

    my $stored = $self->retrieve_data($key);
    return $stored unless defined $stored && length $stored;
    return $stored unless index( $stored, $ENCRYPTION_PREFIX ) == 0;

    my $ciphertext = substr( $stored, length $ENCRYPTION_PREFIX );

    my $encryption = $self->_encryption;
    die "Pay Via Nelnet: '$key' is stored encrypted but Koha's encryption is unavailable."
        . " Set 'encryption_key' in koha-conf.xml.\n"
        unless $encryption;

    my $plaintext = try {
        decode_utf8( $encryption->decrypt_hex($ciphertext) );
    } catch {
        undef;
    };

    # Decrypting with the wrong key doesn't raise an error, it just yields an empty string,
    # so an empty result has to be treated as a failure rather than as an empty credential.
    die "Pay Via Nelnet: unable to decrypt '$key'. The 'encryption_key' in koha-conf.xml"
        . " may have changed. Re-enter the credential in the plugin configuration.\n"
        unless defined $plaintext && length $plaintext;

    return $plaintext;
}

=head3 _set_secret

    $self->_set_secret( 'key', $value );

Stores a credential, encrypted when encryption is available. An empty value is ignored so that
saving the configuration form without retyping the credential keeps the stored one.

=cut

sub _set_secret {
    my ( $self, $key, $plaintext ) = @_;

    return unless defined $plaintext && length $plaintext;

    my $encryption = $self->_encryption;
    unless ($encryption) {
        warn "Pay Via Nelnet: storing '$key' in cleartext because Koha's encryption is"
            . " unavailable. Set 'encryption_key' in koha-conf.xml.";
        $self->store_data( { $key => $plaintext } );
        return;
    }

    $self->store_data( { $key => $ENCRYPTION_PREFIX . $encryption->encrypt_hex( encode_utf8($plaintext) ) } );

    return;
}

=head3 _encrypt_stored_credentials

    $self->_encrypt_stored_credentials;

Encrypts any credential still held in cleartext. Safe to call repeatedly, and never dies: an
instance with no encryption key has to keep working on the cleartext credential it already has.

=cut

sub _encrypt_stored_credentials {
    my ($self) = @_;

    foreach my $key (@CREDENTIAL_KEYS) {
        my $stored = $self->retrieve_data($key);
        next unless defined $stored && length $stored;
        next if index( $stored, $ENCRYPTION_PREFIX ) == 0;

        my $encryption = $self->_encryption;
        unless ($encryption) {
            warn "Pay Via Nelnet: cannot encrypt '$key' because Koha's encryption is"
                . " unavailable. Set 'encryption_key' in koha-conf.xml.";
            next;
        }

        $self->store_data( { $key => $ENCRYPTION_PREFIX . $encryption->encrypt_hex( encode_utf8($stored) ) } );
    }

    return 1;
}

=head3 upgrade

Encrypts credentials that earlier versions of this plugin stored in cleartext.

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    $self->_encrypt_stored_credentials;

    return 1;
}

sub install() {
    my $dbh = C4::Context->dbh();

    my $query = q{
		CREATE TABLE IF NOT EXISTS nelnet_plugin_tokens
		  (
			 token          VARCHAR(128),
			 created_on     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			 borrowernumber INT(11) NOT NULL,
			 PRIMARY KEY (token),
			 CONSTRAINT token_bn FOREIGN KEY (borrowernumber) REFERENCES borrowers (
			 borrowernumber ) ON DELETE CASCADE ON UPDATE CASCADE
		  )
		ENGINE=innodb
		DEFAULT charset=utf8mb4
		COLLATE=utf8mb4_unicode_ci;
    };
    
    $dbh->do($query);

    return 1;
}

sub uninstall() {
    return 1;
}

1;
