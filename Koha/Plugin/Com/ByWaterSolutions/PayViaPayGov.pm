package Koha::Plugin::Com::ByWaterSolutions::PayViaPayGov;

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

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name   => 'Pay Via PayGov',
    author => 'Kyle M Hall',
    description => 'This plugin enables online OPAC fee payments via PayGov',
    date_authored   => '2018-11-27',
    date_updated    => '1900-01-01',
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
        {   template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
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
        PayGovPostUrl           => $self->retrieve_data('PayGovPostUrl'),
        PayGovMerchantCode      => $self->retrieve_data('PayGovMerchantCode'),
        PayGovSettleCode        => $self->retrieve_data('PayGovSettleCode'),
        PayGovApiUrl            => $self->retrieve_data('PayGovApiUrl'),
        PayGovApiPassword       => $self->retrieve_data('PayGovApiPassword'),
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
            template_name => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );
    warn "PayGov: BORROWERNUMBER - $borrowernumber" if $ENABLE_DEBUGGING;

    my $transaction_id = $cgi->param('TransactionId');

    my $merchant_code =
      C4::Context->preference('PayGovMerchantCode');    #33WSH-LIBRA-PDWEB-W
    my $settle_code =
      C4::Context->preference('PayGovSettleCode');      #33WSH-LIBRA-PDWEB-00
    my $password = C4::Context->preference('PayGovApiPassword');    #testpass;

    my $ua  = LWP::UserAgent->new;
    my $url = C4::Context->preference('PayGovApiUrl')
      ;    #https://paydirectapi.ca.link2gov.com/ProcessTransactionStatus;
    my $response = $ua->post(
        $url,
        {
            L2GMerchantCode       => $merchant_code,
            Password              => $password,
            SettleMerchantCode    => $settle_code,
            OriginalTransactionId => $transaction_id,
        }
    );

    my ( $m, $v );

    if ( $response->is_success ) {
        warn "PayGov: RESPONSE CONTENT - ***$response->decoded_content***" if $ENABLE_DEBUGGING;
        my @params = split( '&', uri_unescape( $response->decoded_content ) );
        my $params;
        foreach my $p (@params) {
            my ( $key, $value ) = split( '=', $p );
            $params->{$key} = $value // q{};
        }
        warn "PayGov: INCOMING PARAMS - " . Data::Dumper::Dumper( $params ) if $ENABLE_DEBUGGING;

        if ( $params->{TransactionID} eq $transaction_id ) {

            my $note = "PayGov ( $transaction_id  )";

            unless ( Koha::Account::Lines->search( { note => $note } )->count() ) {

                my @line_items = split( /,/, $cgi->param('LineItems') );
                warn "PayGov: LINE ITEMS - " . Data::Dumper::Dumper( \@line_items ) if $ENABLE_DEBUGGING;

                my @paid;
                my $account = Koha::Account->new( { patron_id => $borrowernumber } );
                foreach my $l (@line_items) {
                    warn "PayGov: LINE ITEM - ***$l***" if $ENABLE_DEBUGGING;
                    $l = substr( $l, 1, length($l) - 2 );
                    my ( undef, $id, $description, $amount ) =
                      split( /[\*,\~]/, $l );

                    warn "PayGov: ACCOUNTLINE TO PAY ID - $id" if $ENABLE_DEBUGGING;
                    warn "PayGov: DESC - $description" if $ENABLE_DEBUGGING;
                    warn "PayGovT: AMOUNT - $amount" if $ENABLE_DEBUGGING;

                    push(
                        @paid,
                        {
                            accountlines_id => $id,
                            description     => $description,
                            amount          => $amount
                        }
                    );

                    $account->pay(
                        {
                            amount     => $amount,
                            lines      => [ scalar Koha::Account::Lines->find($id) ],
                            note       => $note,
                        }
                    );
                }

                $m = 'valid_payment';
                $v = $params->{TransactionAmount};
            }
            else {
                $m = 'duplicate_payment';
                $v = $transaction_id;
            }
        }
        else {
            $m = 'invalid_payment';
            $v = $transaction_id;
        }
    }
    else {
        die( $response->status_line );
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
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments => $self->retrieve_data('enable_opac_payments'),
            PayGovPostUrl      => $self->retrieve_data('PayGovPostUrl'),
            PayGovMerchantCode => $self->retrieve_data('PayGovMerchantCode'),
            PayGovSettleCode   => $self->retrieve_data('PayGovSettleCode'),
            PayGovApiUrl       => $self->retrieve_data('PayGovApiUrl'),
            PayGovApiPassword  => $self->retrieve_data('PayGovApiPassword'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                PayGovPostUrl         => $cgi->param('PayGovPostUrl'),
                PayGovMerchantCode    => $cgi->param('PayGovMerchantCode'),
                PayGovSettleCode      => $cgi->param('PayGovSettleCode'),
                PayGovApiUrl          => $cgi->param('PayGovApiUrl'),
                PayGovApiPassword     => $cgi->param('PayGovApiPassword'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    return 1;
}

sub uninstall() {
    return 1;
}

1;
