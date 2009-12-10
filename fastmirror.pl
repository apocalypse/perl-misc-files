#!/usr/bin/perl
use strict; use warnings;

# Look at F:R:M:R::HOWTO.mirrorcpan
use File::Rsync::Mirror::Recent;

# set some options
my $rsyncserver = 'cpan.cpantesters.org::cpan';
my $mirrortime = 1200;	# pick less if you have a password and/or consent from the upstream

# Generate the frmr objects
my @frmr;
foreach my $p ( qw( authors modules ) ) {
	# Do we have a statusfile?
	if ( -f "$ENV{HOME}/frmr-status-$p.yml" ) {
		# use the thaw constructor!
		my $rrr = File::Rsync::Mirror::Recent->thaw( "$ENV{HOME}/frmr-status-$p.yml" );
		if ( defined $rrr ) {
			push( @frmr, $rrr );
		} else {
			die "Unable to thaw '$ENV{HOME}/frmr-status-$p.yml' into a valid object!";
		}
	} else {
		# Use the normal constructor!
		my $rrr = File::Rsync::Mirror::Recent->new(
			localroot			=> "$ENV{HOME}/CPAN/$p", # your local path
			remote				=> "$rsyncserver/$p/RECENT.recent", # your upstream
			max_files_per_connection	=> 1024 * 10,	# should be a high number if your internet link is good :)
			ttl				=> $mirrortime,
			rsync_options			=> {
#				port			=> 8732, # only for PAUSE
				compress		=> 1,
				links			=> 1,
				times			=> 1,
				checksum		=> 0,
				'omit-dir-times'	=> 1, # not available before rsync 3.0.3
			},
			verbose				=> 1,
			verboselog			=> "$ENV{HOME}/frmr.log",
			_runstatusfile			=> "$ENV{HOME}/frmr-status-$p.yml",
			_logfilefordone			=> "$ENV{HOME}/frmr-done-$p.log",
		);
		if ( defined $rrr ) {
			push( @frmr, $rrr );
		} else {
			die "Unable to construct a valid object!";
		}
	}
}

die "directory $_ doesn't exist, giving up" for grep { ! -d $_->localroot } @frmr;
while () {
	my $ttgo = time + $mirrortime;
	for my $rrr (@frmr){
		print STDERR "Starting rmirror of " . $rrr->localroot . "\n";
		$rrr->rmirror( "skip-deletes" => 1 );
	}
	my $sleep = $ttgo - time;
	if ($sleep >= 1) {
		print STDERR "Sleeping $sleep ...\n";
		sleep $sleep;
	} else {
		print STDERR "No need to sleep ...\n";
	}
}
