#!/usr/bin/perl
use strict; use warnings;

# Get the "class" to load for the data
if ( ! defined $ARGV[0] ) {
	die "Please supply a datafile to process: '$0 Moose.pl'\n";
}

# Get the output dir
my $output_dir = $ARGV[1] || 'gravatars';

# Load the data!
our %AUTHORS;
do $ARGV[0] or die "Unable to load datafile: $! $@";

# Okay, process the authors and get gravatars for them!
if ( ! -d $output_dir ) {
	mkdir( $output_dir ) or die "Unable to mkdir $output_dir: $!";
}
chdir( $output_dir ) or die "Unable to chdir to $output_dir: $!";

# Finally, get our gravatars!
use LWP::Simple qw( getstore get );
use File::Spec;

# Size, in px of the image
my $size = 80;

foreach my $author ( keys %AUTHORS ) {
	# skip images we have
	my $author_image_file = $author . '.png';
	next if -e $author_image_file;

	# Skip unknown authors
	if ( ! defined $AUTHORS{ $author } or ! length $AUTHORS{ $author } ) {
		next;
	}

	# get it!
	# I hate this crap code but URI::Find::Rule seems to bomb out trying to find the gravatar URL...
	my $content = get( 'http://search.cpan.org/~' . $AUTHORS{ $author } );
	if ( defined $content and $content =~ m|\<img\s+src\=\"http\://www\.gravatar\.com/avatar\.php\?gravatar_id\=([^\&]+)\&| ) {
		my $gravatar = $1;

		# Fetch the image!
		my $grav_url = "http://www.gravatar.com/avatar.php?gravatar_id=$gravatar&d=404&size=" . $size;
		warn "Fetching image for '$AUTHORS{ $author }' ($grav_url)...\n";
		my $rc = getstore( $grav_url, $author_image_file );

		# Anything other than a 200 meant we didn't get the image
		if ( $rc != 200 ) {
#			warn "PAUSE id '$author' does not have a gravatar!\n";

			if ( -e $author_image_file ) {
				unlink( $author_image_file ) or die "Unable to remove '$author_image_file': $!\n";
			}
		}
	} else {
		warn "Unable to parse search.cpan.org for gravatar URL for PAUSEid '$AUTHORS{ $author }'\n";
	}

	# Give our internets some rest!
	sleep 1;
}
