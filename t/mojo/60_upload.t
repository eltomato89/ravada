use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use Test::More;
use Test::Mojo;
use Mojo::File 'path';
use Mojo::JSON qw(decode_json);

use lib 't/lib';
use Test::Ravada;

no warnings "experimental::signatures";
use feature qw(signatures);

my $SECONDS_TIMEOUT = 15;

my $t;

my $URL_LOGOUT = '/logout';
my $SCRIPT = path(__FILE__)->dirname->sibling('../script/rvd_front');

################################################################################

sub _clean(@name) {
    for my $name (@name) {
        my $user = Ravada::Auth::SQL->new(name => $name);
        $user->remove() if $user;
    }
}

sub _clean_ldap(@name) {
    for my $name (@name) {
        if ( Ravada::Auth::LDAP::search_user($name) ) {
            Ravada::Auth::LDAP::remove_user($name)  
        }
    }
}

sub _create($type, %users) {
    return if $type eq 'sql';
    while (my ($name, $pass) = each %users) {
        if ( $type eq 'ldap') {
            create_ldap_user($name, $pass);
        }
    }
}

sub test_upload_users( $type, $create=0 ) {

    my ($user1, $pass1) = ( new_domain_name(), $$.1);
    my ($user2, $pass2) = ( new_domain_name(), $$.2);
    _clean_ldap($user1, $user2);

    _create($type, $user1, $pass1, $user2, $pass2) if !$create;
    _clean($user1, $user2);

    my $users = join(":",($user1, $pass1)) ."\n"
                .join(":",($user2, $pass2)) ."\n"
    ;
    $t->post_ok('/admin/users/upload' => form => {
            type => $type
            ,create => $create
            ,users => { content => $users, filename => 'users.txt', 'Content-Type' => 'text/csv' },
    })->status_is(200);
    die $t->tx->res->body if $t->tx->res->code != 200;

    my $response = $t->tx->res->json();
    like($response->{output}, qr/2 users added/);
    is_deeply($response->{error},[]);

    $t->post_ok('/login' => form => {login => $user1, password => $pass1})
        ->status_is(302);
    $t->get_ok('/logout');
    $t->post_ok('/login' => form => {login => $user2, password => $pass2})
        ->status_is(302);
    $t->get_ok('/logout');

    _login($t);
    $t->post_ok('/admin/users/upload' => form => {
            type => 'sql'
            ,users => { content => $users, filename => 'users.txt', 'Content-Type' => 'text/csv' },
})->status_is(200);

    exit if $t->tx->res->code == 401;
    die $t->tx->res->body if $t->tx->res->code != 200;

    $response = $t->tx->res->json();
    like($response->{output}, qr/0 users added/);
    is(scalar(@{$response->{error}}),2);

    test_users_added($type, $user1, $user2);

}

sub test_users_added($type, @name) {
    my $sth = connector->dbh->prepare(
        "SELECT * FROM users WHERE name=?"
    );
    for my $name (@name) {
        $sth->execute($name);
        my $row = $sth->fetchrow_hashref;
        is($row->{name},$name);
        if ($type eq 'sql') {
            is($row->{external_auth}, undef);
        } else {
            is($row->{external_auth},$type,"Expecting $name in $type");
        }
    }
}

sub _login($t) {
    my $user_name = new_domain_name();

    my $user_db = Ravada::Auth::SQL->new( name => $user_name);
    $user_db->remove();

    my $user = create_user($user_name, $$);
    user_admin->make_admin($user->id);

    mojo_login($t, $user_name, $$);
}

################################################################################

$ENV{MOJO_MODE} = 'development';
init('/etc/ravada.conf',0);
my $connector = rvd_back->connector;
like($connector->{driver} , qr/mysql/i) or BAIL_OUT;

$t = Test::Mojo->new($SCRIPT);
$t->ua->inactivity_timeout(900);
$t->ua->connect_timeout(60);

_login($t);
test_upload_users( 'sql' );
test_upload_users( 'ldap', 0 ); # do not create users in Ravada
test_upload_users( 'ldap', 1 ); # create users in Ravada


done_testing();
