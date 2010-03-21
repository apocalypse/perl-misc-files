#!/usr/bin/perl
# Hacked version of the example on http://code.google.com/p/gource/wiki/GravatarExample
# Make sure the config is correct before running this!
use strict; use warnings;

# Size, in px of the image
my $size = 80;

# Set the path to the logfile for processing
my $logpath = File::Spec->catdir( $ENV{HOME}, 'gource_ct', 'ct_dists.log' );
my $output_dir = File::Spec->catdir( $ENV{HOME}, 'gource_ct', 'gravatars' );

# END OF CONFIG

use LWP::Simple qw( getstore get );
use File::Spec;

# Sanity check the output dir
if ( ! -d $output_dir ) {
	mkdir( $output_dir ) or die "Unable to mkdir '$output_dir': $!\n";
}

# Process the git log!
open( my $log, '<', $logpath ) or die "Unable to read log: $!\n";
my %authors;

while( <$log> ) {
	chomp;

	# Grab PAUSE ids
	my $author;
	if ( $_ =~ /^user\:([[:upper:]]+)$/ ) {
		$author = $1;

		next if $authors{$author}++;
	} else {
		next;
	}

	# skip images we have
	my $author_image_file = File::Spec->catfile( $output_dir, $author . '.png' );
	next if -e $author_image_file;

	# get it!
	# I hate this crap code but URI::Find::Rule seems to bomb out trying to find the gravatar URL...
	my $content = get( 'http://search.cpan.org/~' . $author );
	if ( defined $content and $content =~ m|\<img\s+src\=\"http\://www\.gravatar\.com/avatar\.php\?gravatar_id\=([^\&]+)\&| ) {
		my $gravatar = $1;

		# Fetch the image!
		my $grav_url = "http://www.gravatar.com/avatar.php?gravatar_id=$gravatar&d=404&size=" . $size;
		warn "Fetching image for '$author' ($grav_url)...\n";
		my $rc = getstore( $grav_url, $author_image_file );

		# Anything other than a 200 meant we didn't get the image
		if ( $rc != 200 ) {
#			warn "PAUSE id '$author' does not have a gravatar!\n";

			if ( -e $author_image_file ) {
				unlink( $author_image_file ) or die "Unable to remove '$author_image_file': $!\n";
			}
		}
	} else {
		warn "Unable to parse search.cpan.org for gravatar URL for PAUSEid '$author'\n";
	}

	# Give our internets some rest!
	sleep 1;
}

# All done!
close $log or die "Unable to close log: $!\n";
