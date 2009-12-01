#!/usr/bin/perl
use strict; use warnings;

use File::Rsync::Mirror::Recent;

# set some options
my $rsyncserver = 'cpan.cpantesters.org::cpan';
my $mirrortime = 1200;

# setup the dirs we will loop over
my @rrr = map {
	File::Rsync::Mirror::Recent->new(
		localroot                  => "$ENV{HOME}/CPAN/$_", # your local path
		remote                     => "$rsyncserver/$_/RECENT.recent", # your upstream
		max_files_per_connection   => 1024,
		ttl                        => 10,
		rsync_options              => {
#			port              => 8732, # only for PAUSE
			compress          => 1,
			links             => 1,
			times             => 1,
			checksum          => 0,
			'omit-dir-times'  => 1, # not available before rsync 3.0.3
		},
		verbose                    => 1,
		verboselog                 => "$ENV{HOME}/rmirror.log",
	)
} "authors", "modules";

die "directory $_ doesn't exist, giving up" for grep { ! -d $_->localroot } @rrr;
while () {
	my $ttgo = time + 1200; # pick less if you have a password and/or consent from the upstream
	for my $rrr (@rrr){
		$rrr->rmirror ( "skip-deletes" => 1 );
	}
	my $sleep = $ttgo - time;
	if ($sleep >= 1) {
		print STDERR "sleeping $sleep ... ";
		sleep $sleep;
	}
}
