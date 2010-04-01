#!/usr/bin/perl
use strict; use warnings;

# Adapted from BinGOs' http://cpansearch.perl.org/src/BINGOS/App-CPANIDX-0.08/bin/cpanidx-fcgi script
# TODO list:
#	- use SimpleDBI

use POE;
use POE::Component::Server::SimpleHTTP;
use DBI;
use App::CPANIDX::Renderer;
use App::CPANIDX::Queries;

my $port = 11_111;
my $dsn = 'dbi:SQLite:dbname=/home/cpan/CPANIDX.db';
my $debug = 1;

start_httpd();
exit;

# Start the server!
sub start_httpd {
	# Create our own session to receive events from SimpleHTTP
	POE::Session->create(
		inline_states => {
			'_start'	=> \&HTTPD_START,
			'GOT_CPANIDX'	=> \&HTTPD_CPANIDX,
			'GOT_ERROR'	=> \&HTTPD_ERROR,

			'_parent'	=> sub {},
			'_child'	=> sub {},
		},
	);

	# Start POE!
	POE::Kernel->run();
}

sub HTTPD_START {
	$_[KERNEL]->alias_set( 'CPANIDX' );

	my $dbh = DBI->connect( $dsn ) or die $DBI::errstr, "\n";

	POE::Component::Server::SimpleHTTP->new(
		'ALIAS'         =>      'HTTPD',
		'PORT'          =>      $port,
		'HOSTNAME'      =>      'cpanidx.com',
		'HANDLERS'      =>      [
			{
				'DIR'           => '^/CPANIDX/.+/.+',
				'SESSION'       => 'CPANIDX',
				'EVENT'         => 'GOT_CPANIDX',
			},
			{
				'DIR'		=> '.*',
				'SESSION'	=> 'CPANIDX',
				'EVENT'		=> 'GOT_ERROR',
			},
		],
	) or die 'Unable to create the HTTP Server';

	# Store the stuff!
	$_[HEAP]->{dbh} = $dbh;

	return;
}

sub HTTPD_CPANIDX {
	# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
	my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

warn "New CPANIDX request: " . $request->uri->path . "\n" if $debug;

	my( $root, $enc, $type, $search ) = grep { $_ } split m#/#, $request->uri->path;
	$search = '0' if $type =~ /^next/ and !$search;

	my @results = _search_db( $_[HEAP]->{dbh}, $type, $search );
	$enc = 'yaml' unless $enc and grep { lc($enc) eq $_ } App::CPANIDX::Renderer->renderers();
	my $ren = App::CPANIDX::Renderer->new( \@results, $enc );
	my ($ctype, $string) = $ren->render( $type );

	# Do our stuff to HTTP::Response
	$response->header( 'Content-Type' => $ctype );
	$response->code( 200 );
	$response->content( $string );

	# We are done!
	$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
	return;
}

sub HTTPD_ERROR {
	# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
	my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

warn "New error: " . $request->uri->path . "\n" if $debug;

	# Check for errors
	if ( ! defined $request ) {
		$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
		return;
	}

	# Do our stuff to HTTP::Response
	$response->code( 404 );
	$response->content( "Hi visitor, page not found -> '" . $request->uri->path . "'" );

	# We are done!
	$_[KERNEL]->post( 'HTTPD', 'DONE', $response );
	return;
}

sub _search_db {
	my ($dbh,$type,$search) = @_;
	my @results;
	if ( my $sql = App::CPANIDX::Queries->query( $type ) ) {
		if ( $type eq 'mod' and !( $search =~ m#\A[a-zA-Z_][0-9a-zA-Z_]*(?:(::|')[0-9a-zA-Z_]+)*\z# ) ) {
			return @results;
		}

		# send query to dbi
		my $sth = $dbh->prepare_cached( $sql->[0] ) or die $DBI::errstr, "\n";
		$sth->execute( ( $sql->[1] ? $search : () ) );
		while ( my $row = $sth->fetchrow_hashref() ) {
			push @results, { %{ $row } };
		}
	}
	return @results;
}
