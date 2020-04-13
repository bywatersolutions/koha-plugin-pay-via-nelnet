package Koha::Plugin::Com::ByWaterSolutions::PayViaPayNelnet;

use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use URI::Escape qw(uri_unescape);
use LWP::UserAgent;
use JSON qw(from_json);

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name          => 'Pay Via Nelnet',
    author        => 'Kyle M Hall',
    description   => 'This plugin enables online OPAC fee payments via Nelnet',
    date_authored => '2018-11-27',
    date_updated  => '1900-01-01',
    minimum_version => '18.00.00.000',
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

    $template->param(
        borrower             => scalar Koha::Patrons->find($borrowernumber),
        payment_method       => scalar $cgi->param('payment_method'),
        enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
        accountlines         => \@accountlines,
    );

    print $cgi->header();
    print $template->output();
}

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
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

    my $amount   = $vars{Amount};
    my $authcode = $vars{authcode};
    my $order_id = $vars{OrderId};

    my $json = from_json( $vars{OrderToken} );
    warn "JSON: " . Data::Dumper::Dumper($json);

    $borrowernumber = $json->{borrowernumber};
    my $accountlines = $json->{accountlines};
    my $token        = $json->{token};

    my $dbh      = C4::Context->dbh;
    my $query    = "SELECT * FROM paygov_plugin_tokens WHERE token = ?";
    my $token_hr = $dbh->selectrow_hashref( $query, undef, $token );

    my ( $m, $v );
    if ( $authcode eq 'SUCCESS' ) {
        if ($token_hr) {
            my $note = "Nelnet ($order_id)";

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
                                amount     => $amount,
                                note       => $note,
                                library_id => $patron->branchcode,
                                lines      => \@lines,
                            }
                        );
                    }
                );

                $m = 'valid_payment';
                $v = $amount;
            }
            else {
                $m = 'duplicate_payment';
                $v = $trans_id;
            }
        }
        else {
            $m = 'invalid_token';
            $v = $trans_id;
        }
    }
    else {
        $m = 'payment_failed';
        $v = $trans_id;
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
            enable_opac_payments =>
              $self->retrieve_data('enable_opac_payments'),
            NelnetPostUrl      => $self->retrieve_data('NelnetPostUrl'),
            NelnetMerchantCode => $self->retrieve_data('NelnetMerchantCode'),
            NelnetSettleCode   => $self->retrieve_data('NelnetSettleCode'),
            NelnetApiUrl       => $self->retrieve_data('NelnetApiUrl'),
            NelnetApiPassword  => $self->retrieve_data('NelnetApiPassword'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                NelnetPostUrl        => $cgi->param('NelnetPostUrl'),
                NelnetMerchantCode   => $cgi->param('NelnetMerchantCode'),
                NelnetSettleCode     => $cgi->param('NelnetSettleCode'),
                NelnetApiUrl         => $cgi->param('NelnetApiUrl'),
                NelnetApiPassword    => $cgi->param('NelnetApiPassword'),
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
