# Declare our package
package Test::Reporter::POEGateway;
use strict; use warnings;

# Initialize our version
use vars qw( $VERSION );
$VERSION = '0.01';

use POE;
use POE::Component::Server::SimpleHTTP;
use HTTP::Request::Params;
use YAML::Tiny qw( DumpFile );
use Digest::SHA qw( sha1_hex );
use File::Spec;

# the path to save reports
my $REPORT_PATH = "/home/$ENV{USER}/cpan_reports";
my $HTTP_PORT = 11_111;

POE::Session->create(
	package_states => [
		'Test::Reporter::POEGateway', => [ qw(_start _stop _child got_req) ],
	],
);

# Start POE!
POE::Kernel->run();
exit;

# initializes the httpd
sub _start {
	$_[KERNEL]->alias_set( 'gateway' );

	# spawn the httpd
	POE::Component::Server::SimpleHTTP->new(
		'ALIAS'		=> 'HTTPD',
		'PORT'		=> $HTTP_PORT,
		'HOSTNAME'	=> 'POEGateway.net',
		'HANDLERS'	=> [
			{
				'DIR'		=> '.*',
				'SESSION'	=> 'gateway',
				'EVENT'		=> 'got_req',
			},
		],
	) or die 'Unable to create httpd';

	return;
}

sub _child {
	return;
}

sub _stop {
	return;
}

sub got_req {
	# ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
	my( $request, $response, $dirmatch ) = @_[ ARG0 .. ARG2 ];

	# a sane Test::Reporter submission?
	# mostly copied from Test::Reporter::HTTPGateway, thanks!
	my $form = HTTP::Request::Params->new({ req => $request })->params;
	foreach my $v ( qw( from subject via report ) ) {
		if ( ! exists $form->{ $v } or ! defined $form->{ $v } or ! length( $form->{ $v } ) ) {
			$response->code( 500 );
			$response->content( "ERROR: Missing $v field" );
			last;
		}

		next if $v eq 'report';
		if ( $form->{ $v } =~ /[\r\n]/ ) {
			$response->code( 500 );
			$response->content( "ERROR: Malformed $v field" );
			last;
		}
	}

	# Do we need to check key?
	if ( ! key_allowed( $form->{'key'} ) ) {
		$response->code( 401 );
		$response->content( 'Access denied, please supply a correct key.' );
	}

	# not a malformed request...
	if ( ! defined $response->code ) {
		# store the request somewhere
		save_report( $form, $request, $response );

		# Do our stuff to HTTP::Response
		$response->code( 200 );
		$response->content( 'Report Submitted.' );
	}

	# We are done!
	$_[KERNEL]->post( 'HTTPD', 'DONE', $response );

	return;
}

# does the brunt work of saving posted reports
sub save_report {
	my( $form, $request, $response ) = @_;

	# add some misc info
	$form->{'_sender'} = $response->connection->remote_ip;
	$form->{'via'} .= ', via ' . __PACKAGE__ . ' ' . $VERSION;

	# calculate the filename
	my $filename = time() . '.' . sha1_hex( $form->{'report'} );

	print "Saving $form->{subject} report to $filename\n";
	DumpFile( File::Spec->catfile( $REPORT_PATH, $filename ), $form );

	return;
}

# If you want to set a key, override this
sub key_allowed {
	return 1;
}

1;
__END__
