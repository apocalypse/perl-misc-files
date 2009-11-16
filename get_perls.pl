#!/usr/bin/perl
use strict; use warnings;

use LWP::UserAgent;
use HTML::LinkExtor;
use URI::URL;
use File::Spec;
use IO::Handle;

# the url of the perl versions
my $url = "http://www.cpan.org/src/5.0/";

# where do we save the tarballs?
my $dir = "/home/apoc/perl/build";

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

	foreach my $p ( sort keys %perls ) {
		my $path = File::Spec->catfile( $dir, $p );

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
		return if $l ne 'href';

		# we're only interested in "perl-X.X.X.tar.gz" files
		if ( $links{$l} =~ /^perl\-(\d+)\.(\d+)\.(\d+)\.tar\.gz$/ ) {
			# only retrieve stable versions - even minor number
			if ( $2 % 2 == 0 ) {
				#print "Found Perl: $links{$l}\n";
				$perls{ $links{$l} } = 1;
			}
		}
	}

	return;
}

# all done...
