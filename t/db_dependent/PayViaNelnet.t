#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 9;
use Test::Exception;

use Koha::Database;
use Koha::Encryption;

use t::lib::Mocks;

use Koha::Plugin::Com::ByWaterSolutions::PayViaNelnet;

my $schema = Koha::Database->new->schema;

my $PREFIX = $Koha::Plugin::Com::ByWaterSolutions::PayViaNelnet::ENCRYPTION_PREFIX;

t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

my $plugin = Koha::Plugin::Com::ByWaterSolutions::PayViaNelnet->new( { enable_plugins => 1 } );

# Every subtest calls upgrade() directly. It can't be triggered the normal way here because
# $VERSION is the literal string '{VERSION}' until the kpz is built, so Koha's version
# comparison in Koha::Plugins::Base always decides this is a downgrade and skips the hook.

subtest 'upgrade() migrates a cleartext credential' => sub {
    plan tests => 5;
    $schema->storage->txn_begin;

    $plugin->store_data( { key => 'cleartext-shared-secret' } );
    unlike( $plugin->retrieve_data('key'), qr/^\Q$PREFIX\E/, 'stored value starts out unencrypted' );

    is( $plugin->upgrade, 1, 'upgrade() returns 1' );

    my $stored = $plugin->retrieve_data('key');
    like( $stored, qr/^\Q$PREFIX\E/, 'stored value now carries the encryption prefix' );
    isnt( $stored, 'cleartext-shared-secret', 'stored value is no longer the cleartext credential' );
    is( $plugin->_get_secret('key'), 'cleartext-shared-secret', 'the original credential is recoverable' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() is idempotent' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->store_data( { key => 'cleartext-shared-secret' } );
    $plugin->upgrade;
    my $after_first = $plugin->retrieve_data('key');

    is( $plugin->upgrade, 1, 'a second upgrade() returns 1' );
    is( $plugin->retrieve_data('key'), $after_first, 'the stored value is byte-identical, so it was not re-encrypted' );
    is( $plugin->_get_secret('key'), 'cleartext-shared-secret', 'the credential still decrypts to the original' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() handles an empty or absent credential' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    $plugin->store_data( { key => undef } );
    is( $plugin->upgrade, 1, 'upgrade() returns 1 with no credential stored' );
    is( $plugin->retrieve_data('key'), undef, 'nothing was written' );

    $plugin->store_data( { key => q{} } );
    is( $plugin->upgrade, 1, 'upgrade() returns 1 with an empty credential' );
    is( $plugin->retrieve_data('key'), q{}, 'the empty value was left as-is, not encrypted' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() is a no-op without an encryption key' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'encryption_key', q{} );

    $plugin->store_data( { key => 'cleartext-shared-secret' } );

    my $returned;
    lives_ok { $returned = $plugin->upgrade } 'upgrade() does not die, so the plugin cannot vanish from the plugin list';
    is( $returned, 1, 'upgrade() still returns 1, so Koha will not retry it forever' );
    is( $plugin->retrieve_data('key'), 'cleartext-shared-secret', 'the credential is left in cleartext and still usable' );

    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

    $schema->storage->txn_rollback;
};

subtest 'migration runs later once an encryption key is configured' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'encryption_key', q{} );
    $plugin->store_data( { key => 'cleartext-shared-secret' } );
    $plugin->upgrade;
    is( $plugin->retrieve_data('key'), 'cleartext-shared-secret', 'still cleartext while no key is set' );

    # The one-shot upgrade() hook will never fire again, so opening the configuration page
    # has to be able to finish the migration
    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );
    $plugin->_encrypt_stored_credentials;

    like( $plugin->retrieve_data('key'), qr/^\Q$PREFIX\E/, 'encrypted once a key is available' );
    is( $plugin->_get_secret('key'), 'cleartext-shared-secret', 'the credential is unchanged' );

    $schema->storage->txn_rollback;
};

subtest '_set_secret() and _get_secret() round-trip' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->_set_secret( 'key', 'a-brand-new-key' );

    my $stored = $plugin->retrieve_data('key');
    like( $stored, qr/^\Q$PREFIX\E/, 'the value was stored with the encryption prefix' );
    unlike( $stored, qr/a-brand-new-key/, 'the cleartext credential does not appear in the stored value' );
    is( $plugin->_get_secret('key'), 'a-brand-new-key', 'the credential round-trips' );

    $schema->storage->txn_rollback;
};

subtest '_get_secret() passes through unencrypted values' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    $plugin->store_data( { key => 'legacy-cleartext' } );
    is( $plugin->_get_secret('key'), 'legacy-cleartext', 'an unprefixed value is returned as-is' );

    $plugin->store_data( { key => undef } );
    is( $plugin->_get_secret('key'), undef, 'a missing credential returns undef rather than dying' );

    $schema->storage->txn_rollback;
};

subtest '_get_secret() fails closed' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    $plugin->store_data( { key => $PREFIX . 'deadbeefdeadbeef' } );
    throws_ok { $plugin->_get_secret('key') } qr/unable to decrypt/,
        'a corrupted credential dies instead of being sent to Nelnet';

    $plugin->_set_secret( 'key', 'a-brand-new-key' );
    t::lib::Mocks::mock_config( 'encryption_key', q{} );
    throws_ok { $plugin->_get_secret('key') } qr/encryption is unavailable/,
        'an encrypted credential dies when the key is gone';
    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

    $schema->storage->txn_rollback;
};

subtest 'a blank credential does not overwrite the stored one' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->_set_secret( 'key', 'the-real-key' );
    my $stored = $plugin->retrieve_data('key');

    $plugin->_set_secret( 'key', q{} );
    is( $plugin->retrieve_data('key'), $stored, 'an empty submitted value leaves the stored credential alone' );

    $plugin->_set_secret( 'key', undef );
    is( $plugin->retrieve_data('key'), $stored, 'an absent submitted value leaves the stored credential alone' );

    my $template = $plugin->mbf_read('configure.tt');
    unlike( $template, qr/name="key"[^>]*value="\[%\s*key/,
        'configure.tt never renders the stored credential back into the form field' );

    $schema->storage->txn_rollback;
};
