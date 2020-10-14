package Koha::Plugin::Com::ByWaterSolutions::PayViaNelnet;

use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use List::Util qw(sum);
use Digest::SHA qw(sha256_hex);
use URI::Encode;
use Time::HiRes qw(gettimeofday);

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
    $url_params->[12] = { key => 'key', val => $self->retrieve_data('key') };

    my $combined_url_values = join( '', map { $_->{val}} @$url_params );
    my $sha256 = sha256_hex( $combined_url_values );

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

                my @lines = Koha::Account::Lines->search({ accountlines_id => { -in => $accountlines} });
                #warn "ACCOUNTLINES TO PAY: " . Data::Dumper::Dumper( $_->unblessed ) for @lines;

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

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            url => $self->retrieve_data('url'),
            orderType => $self->retrieve_data('order_type'),
            key => $self->retrieve_data('key'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                order_type        => $cgi->param('orderType'),
                key   => $cgi->param('key'),
                url => $cgi->param('url'),
            }
        );
        $self->go_home();
    }
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

    return 1;
}

sub uninstall() {
    return 1;
}

1;
