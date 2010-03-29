#!/usr/bin/perl
# File taken from examples/moo.pl in the relay server dist
use strict; use warnings;

BEGIN { eval "use IO::Poll;"; }

use POE qw( Component::Metabase::Relay::Server );
my $test_httpd = POE::Component::Metabase::Relay::Server->spawn(
	port	=> 11_111,
	id_file	=> '/home/cpan/.metabase/id.json',
	dsn	=> 'dbi:SQLite:dbname=/home/cpan/CPANTesters.db',
	uri	=> 'https://metabase.cpantesters.org/beta/',
	debug	=> 1,
);

$poe_kernel->run();
exit 0;
