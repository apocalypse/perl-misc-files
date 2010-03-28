#!/usr/bin/perl
use strict; use warnings;
use Encode;

# chdir to the git source path
if ( defined $ARGV[0] and -d $ARGV[0] ) {
	chdir( $ARGV[0] ) or die "Unable to chdir to $ARGV[0]: $!";
} else {
	die "Please supply a path to the git repository: '$0 Moose/\n";
}

# Get the authors
my %authors;
{
	my @authors = `git log --pretty=format:user:%aN --reverse --raw --encoding=UTF-8 --no-renames | grep "user:*" | cut -c 6-100 | sort -u`;
	foreach my $a ( @authors ) {
		chomp $a;
		my $len = length ( decode( "utf8", $a ) );
		$authors{ $a } = $len;
	}
}

# Get the "longest" author name, heh
my $longest = 0;
foreach my $a ( keys %authors ) {

	if ( $authors{$a} > $longest ) {
		$longest = $authors{$a};
	}
}

# Make sure the longest ends perfectly aligned with a tab boundary
if ( $longest % 8 != 0 ) {
	$longest += abs( $longest - ( 8 * ( int($longest / 8) + 1 ) ) );
}

# Make the output
my $output = "our \%AUTHORS = (\n";

# Sort the authors
# TODO - why is this not sorted right? - my LANG is LANG=en_US.UTF-8
#	"Yuval Kogman"			=> 'PAUSEID',
#	"Ævar Arnfjörð Bjarmason"	=> 'PAUSEID',

foreach my $a ( sort { lc($a) cmp lc($b) } keys %authors ) {
	# Figure out how many tabs we need :)
	my $charsdiff = ( $longest - $authors{ $a } ) - 2; # subtract two for the "$a"

	my $tabs = int( $charsdiff / 8 );
	if ( $charsdiff % 8 != 0 ) {
		$tabs++;	# +1 so it lines up properly
	}

	$output .= "\t\"$a\"" . ( "\t" x $tabs ) . "=> '',\n";
}

$output .= ");\n";
print $output;
