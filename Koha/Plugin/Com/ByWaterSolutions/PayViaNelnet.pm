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
use Digest::SHA qw(sha256);

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

    my $url_params = {};
    $url_params->{userChoice1} = $patron->id; # Borrowernumber for verification
    $url_params->{userChoice2} = join( ',', map { $_->id } @accountlines ); # Accountlines to pay
    $url_params->{userChoice3} = $token; # Token we generate to avoid duplicate or false payments in Koha
    $url_params->{orderType} = $self->retrieve_data('order_type');
    $url_params->{orderNumber} = $accountlines[0]->id;
    $url_params->{orderName} = $patron->firstname . $patron->surname;
    $url_params->{orderDescription} = "Payment of library fees";
    $url_params->{amount} = sum( map { $_->amountoutstanding } @accountlines );
    $url_params->{redirectUrl} = C4::Context->preference('OPACBaseURL') . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::ByWaterSolutions::PayViaPayGov";
    $url_params->{redirectUrlParameters} = "userChoice1,userChoice2,userChoices3,transactionType,transactionStatus,transactionId,transactionResultCode,transactionResultMessage,orderAmount";
    $url_params->{retriesAllowed} = 1;
    $url_params->{timestamp} = time;
    $url_params->{key} = $self->retrieve_data('key');

    my $combined_url_values = join( ',', values %$url_params );
    my $sha256 = Digest::SHA::sha256( $combined_url_values );
    $url_params->{hash} = $sha256;

    $template->param(
        borrower             => $patron,
        payment_method       => scalar $cgi->param('payment_method'),
        enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
        accountlines         => \@accountlines,
        url                  => $self->retrieve_data('url'),
        url_params           => $url_params,
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
    warn "NELNET INCOMING: " . Data::Dumper::Dumper( \%vars );

    my $borrowernumber = $vars{userChoice1};
    my $accountline_ids = $vars{userChoice2};
    my $token = $vars{userChoice3};

    my $type = $vars{transactionType};
    my $transaction_status = $vars{transactionStatus};
    my $transaction_id = $vars{transactionId};
    my $transaction_result_code = $vars{transactionResultCode};
    my $transaction_result_message = $vars{transactionResultMessage};
    my $order_amount = $vars{orderAmount};

    my $dbh      = C4::Context->dbh;
    my $query    = "SELECT * FROM paygov_plugin_tokens WHERE token = ?";
    my $token_hr = $dbh->selectrow_hashref( $query, undef, $token );

    my $accountlines = [ split( ',', $accountline_ids ) ];

    my ( $m, $v );
    if ( $logged_in_borrowernumber ne $borrowernumber ) {
        $m = 'not_same_patron';
        $v = $transaction_id;
    }
    elsif ( $transaction_status eq '1' ) { # Success
        if ($token_hr) {
            my $note = "Nelnet ($transaction_id)";

            # If this note is found, it must be a duplicate post
            unless (
                Koha::Account::Lines->search( { note => $note } )->count() )
            {

                my $patron  = Koha::Patrons->find($borrowernumber);
                my $account = $patron->account;

                my $schema = Koha::Database->new->schema;

                my @lines = Koha::Account::Lines->search({ accountlines_id => { -in => $accountlines} });
                warn "ACCOUNTLINES TO PAY: ";
                warn Data::Dumper::Dumper( $_->unblessed ) for @lines;

               $schema->txn_do(
                    sub {
                        $dbh->do(
                            "DELETE FROM paygov_plugin_tokens WHERE token = ?",
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
		CREATE TABLE IF NOT EXISTS paygov_plugin_tokens
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
