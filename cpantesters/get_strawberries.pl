#!/usr/bin/perl
use strict; use warnings;

use LWP::UserAgent;
use HTML::LinkExtor;
use URI::URL;
use File::Spec;
use IO::Handle;
use File::Path::Tiny;

# the url of the perl versions
my $url = "http://strawberryperl.com/releases.html";

# where do we save the tarballs?
my $dir = "/home/cpan/STRAWBERRY_PERL";

# supply optional LWP params here...
my $ua = LWP::UserAgent->new;

# disable buffering
STDOUT->autoflush(1);

# get the document and extract the links
my %perls;
get_perl_versions( );

# Retrieve the perl version list
sub get_perl_versions {
	my $link = HTML::LinkExtor->new( \&save_links );
	print "Downloading Perl versions list...";
	my $res = $ua->request( HTTP::Request->new( GET => $url ), sub { $link->parse( $_[0] ) } );
	if ( ! $res->is_success ) {
		print " FAILURE: " . $res->code . "\n";
	} else {
		# process the list!
		print " SUCCESS\n";
		download_perl_versions( $res->base );
	}

	return;
}

# download the perls!
sub download_perl_versions {
	my $base = shift;

	# Make sure the dir we want is writable!
	if ( ! -d $dir ) {
		File::Path::Tiny::mk( $dir ) or die "Unable to mkdir '$dir': $!";
	}

	foreach my $p ( sort keys %perls ) {
		my $path = File::Spec->catfile( $dir, ( File::Spec->splitpath( $p ) )[2] );

		# skip download if we already have it
		if ( -f $path ) {
			print "Skipping download of $p because file exists...\n";
			next;
		}

		# actually retrieve it!
		print "Downloading $p...";
		my $res = $ua->mirror( url( $p, $base )->abs, $path );
		if ( ! $res->is_success ) {
			print " FAILURE: " . $res->code . "\n";
		} else {
			print " SUCCESS\n";
		}
	}
}

# callback routine for LinkExtor
sub save_links {
	my( $tag, %links ) = @_;

	# we're only interested in non-image links
	return if $tag ne 'a';
	foreach my $l ( keys %links ) {
		next if $l ne 'href';

		# we're only interested in the regular ZIP versions
		if ( $links{$l} =~ /(?<!portable)\.zip$/ ) {
			#print "Found Perl: $links{$l}\n";
			$perls{ $links{$l} } = 1;
		}
	}

	return;
}

# all done...
