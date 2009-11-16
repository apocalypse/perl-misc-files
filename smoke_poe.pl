#!/usr/bin/perl
use strict; use warnings;

# load our dependencies
use Capture::Tiny qw( capture_merged tee_merged );
use Data::Dumper;
use File::ReadBackwards;

# this script does everything, but we need some layout to be specified!
# /home/apoc				<-- the main directory
# /home/apoc/poe/trunk/poe
# /home/apoc/poe/trunk/poe-test-loops
# /home/apoc/perl/perl-5.6.1

# various extra setup:
# win32:
#	strawberry-5.10.0.4:
#		Win32::Console, Tk, Event

# default DEBUG is 0
my $DEBUG = $ARGV[0] || 0;

# get our installed perl versions
opendir( PERLVERS, "/home/$ENV{USER}/perl/" ) or die "Unable to opendir: $!";
my @perlvers = readdir( PERLVERS ) or die "Unable to readdir: $!";
closedir( PERLVERS ) or die "Unable to closedir: $!";

# filter the list for our perl dirs
@perlvers = grep { $_ =~ /^perl-/ and -d "/home/$ENV{USER}/perl/$_" } @perlvers;
@perlvers = sort { $a cmp $b } @perlvers;

# cleanup PTL
chdir( "/home/$ENV{USER}/poe/trunk/poe-test-loops" ) or die "Unable to chdir: $!";
do_shellcommand( "make distclean" ) if -e 'Makefile';

# Okay, install latest poe-test-loops on those versions
foreach my $ver ( @perlvers ) {
	print "[SMOKER] Installing POE-Test-Loops on $ver...";
	do_shellcommand( "/home/$ENV{USER}/perl/$ver/bin/perl Makefile.PL" );
	my $result = do_shellcommand( "make test" );
	if ( $result->[-1] =~ /PASS/ ) {
		$result = do_shellcommand( "make install" );
		if ( $result->[-1] =~ /Appending installation info/ ) {
			print " OK\n";
		} else {
			print " FAILED\n";
		}
	} else {
		print " FAILED!\n";
	}

	do_shellcommand( "make distclean" );
}

# Cleanup POE
chdir( "/home/$ENV{USER}/poe/trunk/poe" ) or die "Unable to chdir: $!";
do_shellcommand( "make distclean" ) if -e 'Makefile';

# Now, the POE tests!
foreach my $ver ( @perlvers ) {
	print "[SMOKER] Testing POE on $ver...";

	# Limit the test to 2m for sanity...
	eval {
		local $SIG{ALRM} = sub { die "alarm\n" };
		alarm 2 * 60;

		# do it!
		system( "/home/$ENV{USER}/perl/$ver/bin/perl Makefile.PL --default" );
		system( "make test > /home/$ENV{USER}/poe.smoke.$ver 2>&1" );

		# ok, did not timeout!
		alarm 0;

		# analyze the output
		my $bw = File::ReadBackwards->new( "/home/$ENV{USER}/poe.smoke.$ver" ) or die "Unable to open: $!";
		my $lastline = $bw->readline;
		$bw->close;
		if ( $lastline =~ /PASS/ ) {
			print " OK\n";
		} else {
			print " FAILED\n";
		}
	};
	if ( $@ ) {
		if ( $@ =~ /^alarm/ ) {
			print " FAILED(timedout)\n";
		} else {
			die " FAILED($@)\n";
		}
	}

#	my $result = do_shellcommand( "/home/$ENV{USER}/perl/$ver/bin/perl Makefile.PL --default; make test" );
#	if ( $result->[-1] =~ /PASS/ ) {
#		print " OK\n";
#	} else {
#		print " FAILED!\n";
#
#		# Save the test failure somewhere
#		open( my $fh, '>', "/home/$ENV{USER}/poe.smoke.$ver" ) or die "Unable to open fh: $!";
#		foreach my $line ( @$result ) {
#			print $fh $line, "\n";
#		}
#		close( $fh ) or die "Unable to close fh: $!";
#	}

	do_shellcommand( "make distclean" );
}

sub do_shellcommand {
	my $cmd = shift;

	my $output;
	if ( $DEBUG ) {
		print "[SMOKER] Executing $cmd\n";
		$output = tee_merged { system( $cmd ) };
	} else {
		$output = capture_merged { system( $cmd ) };
	}
	my @output = split( /\n/, $output );
	return \@output;
}
