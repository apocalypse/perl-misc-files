#!/usr/bin/perl
use strict; use warnings;

# This script takes the cpanstats DB and outputs it into a format
# that Gource likes. This script specifically outputs the graph of
# all dists tested.

# Grab the cpanstats DB from http://devel.cpantesters.org/cpanstats.db.bz2
# Get the cpantesters mapping from a magic fairy ;)

# Warning: the resulting log will be ~900M as of March 16, 2010!

# TODO use Term::ProgressBar and calculate the total number of rows + update the term...
# TODO steal the gravatar script from POE and get gravatars for all PAUSE ids we detect

# some misc configs
my $cpanstats = '/home/apoc/Desktop/cpanstats.db';
my $cpan_map = '/home/apoc/Desktop/cpantesters_mapping.txt';

# Load our modules!
use DBI;
use DateTime;

main();

sub main {
	# Load the cpantesters mapping
	load_cpantesters_map();

	# Connect to the sqlite DB!
	my $dbh = DBI->connect( "dbi:SQLite:dbname=$cpanstats", '', '', {
		'PrintError'	=>	1,
		'PrintWarn'	=>	1,
		'RaiseError'	=>	1,
		'TraceLevel'	=>	0,
	} );

	# Pull out each upload and process it
	# TODO should be ORDER BY date but it blows up? The column is not a true date column so...
	my $sth = $dbh->prepare( 'SELECT date, dist, tester FROM cpanstats ORDER BY id' );
	$sth->execute;
	my $newdata;
	$sth->bind_columns( \( @$newdata{ @{ $sth->{'NAME_lc'} } } ) );

	# Start with the header
	# set the date as 935824000 which is right before id 1 in the DB :)
	print "user:APOCAL\n935824000\n:000000 100644 0000000... AAAAAAA... A	/\n\n";

	while ( $sth->fetch() ) {
		# Process this report
		process_report( $newdata );
	}
	$sth->finish;
	undef $sth;
	$dbh->disconnect;
	undef $dbh;
	return;
}

# Stores the uploader -> name mapping
my %cpantesters_map;

sub load_cpantesters_map {
	my %temp;

	open( my $fh, '<', $cpan_map ) or die "Unable to load '$cpan_map': $!";
	while ( <$fh> ) {
		chomp;
		my ( $email, $name ) = $_ =~ m{\A(.+),(.+)\z};
		die "Couldn't parse >>>$_<<<" unless $email && $name;
		push @{ $temp{ $name } }, $email;
	}
	close( $fh ) or die "Unable to close '$cpan_map': $!";

	# reverse it so we can search by email and get the name
	foreach my $name ( keys %temp ) {
		foreach my $email ( @{ $temp{ $name } } ) {
			$cpantesters_map{ $email } = $name;
		}
	}
}

sub find_cpantesters_map {
	my $email = shift;

	# Sanity
	return 'UNKNOWN' if ! defined $email or ! length $email;
	if ( exists $cpantesters_map{ $email } ) {
		return $cpantesters_map{ $email };
	} else {
		return $email;
	}
}

# Stores the tree we've used to generate the layout
# top-level: "perl"
# sub-level: perl versions
# sub-sub level: osname
# sub-sub-sub level: platform-osver
my %tree;

sub process_report {
	my $r = shift;
	my %report = %$r;

#	use Data::Dumper;
#	print Dumper( \%report );

	# Mangle the date into an epoch
	# from CPAN::Testers::Data::Generator: whereas the 'date' field refers to the YYYYMMDDhhmm formatted date and time.
	if ( $report{date} =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})$/ ) {
		$report{date} = DateTime->new(
			year	=> $1,
			month	=> $2,
			day	=> $3,
			hour	=> $4,
			minute	=> $5,
		)->epoch;
	} else {
		warn "Invalid date in report: $report{date}";
		return;
	}

	# Cleanup some vars
	$report{tester} = find_cpantesters_map( $report{tester} );
	my @dist = split( '-', $report{dist} );

	# walk the tree and check if this is a new dist or not
	my $walktree = \%tree;
	my $newdist = 0;
	foreach my $mod ( @dist ) {
		if ( ! exists $walktree->{ $mod } ) {
			$newdist++;
			$walktree->{ $mod } = {};
		}

		$walktree = $walktree->{ $mod };
	}

	# Generate the git output!
	my $output = "user:$report{tester}\n";
	$output .= $report{date} . "\n";

	# we don't include the dist version because it makes the graph too crazy :(

	# make the top-level split like D/DB/DBI so the graph looks better
	my $toplevel = uc( substr( $dist[0], 0, 1 ) . '/' . substr( $dist[0], 0, 2 ) );

	# git output is:
	#:000000 100644 0000000... bd3b6ca... A	poe/lib/POE/Kernel.pm
	#:000000 100644 0000000... 83c9f1a... A	poe/lib/POE/Session.pm
	#:100644 100644 bd3b6ca... 63d6c22... M	poe/lib/POE/Kernel.pm
	#:(old file mask - 0 if A) (new file mask - 0 if A) (parent guid - 0 if A) (new guid) (mode - A for add, M for modify) (path)
	# Make the graph easier to see by putting the dist as the filename
	if ( $newdist ) {
		# new dist!

		$output .= ":000000 100644 0000000... AAAAAAA... A\t/$toplevel/" . join( '/', @dist ) . "/$report{dist}\n";
	} else {
		# same dist

		$output .= ":100644 100644 AAAAAAA... AAAAAAA... M\t/$toplevel/" . join( '/', @dist ) . "/$report{dist}\n";
	}
	$output .= "\n";

	print $output;
	return;
}

__END__

# to generate the video, run this script and save the log, then run Gource like this:
# You would need to experiment with the "-r 100" param to ffmpeg to get an optimal video!
gource ct_dists.log -1280x720 --highlight-all-users --multi-sampling --user-scale 0.5 \
  --disable-bloom --elasticity 0.0001 --max-file-lag 0.000001 --max-files 1000000 \
  --date-format "CPANTesters Reports For Dists On %B %d, %Y %X" --stop-on-idle --file-idle-time 100 \
  --colour-images --user-friction 0.0000001 --seconds-per-day 0.000001 --hide dirnames --camera-mode overview \
  --output-ppm-stream - | ffmpeg -y -b 5000K -r 100 -f image2pipe -vcodec ppm -i - -vcodec mpeg4 gource_CT_dists.mp4

# I tried using -r200 but ffmepg didn't like it:
#[mpeg4 @ 0x202f040]bitrate tolerance too small for bitrate
#Error while opening codec for output stream #0.0 - maybe incorrect parameters such as bit_rate, rate, width or height


apoc@blackhole:~/othergit/poe$ gource --git-log-command perl/
git log --pretty=format:user:%aN%n%ct --reverse --raw --encoding=UTF-8 --no-renames

# from man git log:
# %aN: author name (respecting .mailmap, see git-shortlog(1) or git-blame(1))
# %ct: committer date, UNIX timestamp
# %n: newline

# It looks something like this:

apoc@blackhole:~/othergit/poe$ git log --pretty=format:user:%aN%n%ct --reverse --raw --encoding=UTF-8 --no-renames
user:(no author)
902692078
user:troc
902692078
:000000 100644 0000000... bd3b6ca... A	poe/lib/POE/Kernel.pm
:000000 100644 0000000... 83c9f1a... A	poe/lib/POE/Session.pm
:000000 100755 0000000... cb894d8... A	poe/samples/sessions.perl

user:troc
902718149
:000000 100755 0000000... 1cca884... A	poe/samples/forkbomb.perl

user:troc
902718224
:100644 100644 83c9f1a... 409f349... M	poe/lib/POE/Session.pm

user:troc
902718270
:100644 100644 bd3b6ca... 63d6c22... M	poe/lib/POE/Kernel.pm

user:troc
902718309
:100755 100755 cb894d8... 07795ee... M	poe/samples/sessions.perl

user:troc
902781107
:000000 100755 0000000... 1de58f2... A	poe/samples/selects.perl

$VAR1 = {
          'version' => '1.01',
          'date' => '199908280708',
          'dist' => 'Bundle-ABH',
          'osvers' => '',
          'state' => 'cpan',
          'perl' => '0',
          'osname' => '',
          'postdate' => '199908',
          'platform' => '',
          'id' => 1,
          'guid' => '00000001-b19f-3f77-b713-d32bba55d77f',
          'type' => 1,
          'tester' => 'ABH'
        };
$VAR1 = {
          'version' => '2.08',
          'date' => '199908280732',
          'dist' => 'Apache-SSI',
          'osvers' => '',
          'state' => 'cpan',
          'perl' => '0',
          'osname' => '',
          'postdate' => '199908',
          'platform' => '',
          'id' => 2,
          'guid' => '00000002-b19f-3f77-b713-d32bba55d77f',
          'type' => 1,
          'tester' => 'KWILLIAMS'
        };
$VAR1 = {
          'version' => '1.02',
          'date' => '199908281059',
          'dist' => 'Bundle-ABH',
          'osvers' => '',
          'state' => 'cpan',
          'perl' => '0',
          'osname' => '',
          'postdate' => '199908',
          'platform' => '',
          'id' => 3,
          'guid' => '00000003-b19f-3f77-b713-d32bba55d77f',
          'type' => 1,
          'tester' => 'ABH'
        };
$VAR1 = {
          'version' => '1.01',
          'date' => '199908281238',
          'dist' => 'Lingua-PT-Conjugate',
          'osvers' => '',
          'state' => 'cpan',
          'perl' => '0',
          'osname' => '',
          'postdate' => '199908',
          'platform' => '',
          'id' => 4,
          'guid' => '00000004-b19f-3f77-b713-d32bba55d77f',
          'type' => 1,
          'tester' => 'EGROSS'
        };
$VAR1 = {
          'version' => '1.02',
          'date' => '199908281250',
          'dist' => 'OpenCA-TRIStateCGI',
          'osvers' => '',
          'state' => 'cpan',
          'perl' => '0',
          'osname' => '',
          'postdate' => '199908',
          'platform' => '',
          'id' => 5,
          'guid' => '00000005-b19f-3f77-b713-d32bba55d77f',
          'type' => 1,
          'tester' => 'MADWOLF'
        };
$VAR1 = {
          'version' => '0.48',
          'date' => '199908281214',
          'dist' => 'FCGI',
          'osvers' => '2.7',
          'state' => 'unknown',
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'postdate' => '199908',
          'platform' => 'sun4-solaris',
          'id' => 6,
          'guid' => '00000006-b19f-3f77-b713-d32bba55d77f',
          'type' => 2,
          'tester' => 'schinder@pobox.com'
        };
$VAR1 = {
          'version' => '0.48',
          'date' => '199908281215',
          'dist' => 'FCGI',
          'osvers' => '10.20',
          'state' => 'unknown',
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'postdate' => '199908',
          'platform' => 'PA-RISC1.1',
          'id' => 7,
          'guid' => '00000007-b19f-3f77-b713-d32bba55d77f',
          'type' => 2,
          'tester' => 'schinder@pobox.com'
        };
$VAR1 = {
          'version' => '0.1133',
          'date' => '199908281219',
          'dist' => 'HTML-EP',
          'osvers' => '10.20',
          'state' => 'pass',
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'postdate' => '199908',
          'platform' => 'PA-RISC1.1',
          'id' => 9,
          'guid' => '00000009-b19f-3f77-b713-d32bba55d77f',
          'type' => 2,
          'tester' => 'schinder@pobox.com'
        };
$VAR1 = {
          'version' => '0.1133',
          'date' => '199908281222',
          'dist' => 'HTML-EP',
          'osvers' => '2.7',
          'state' => 'pass',
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'postdate' => '199908',
          'platform' => 'sun4-solaris',
          'id' => 12,
          'guid' => '00000012-b19f-3f77-b713-d32bba55d77f',
          'type' => 2,
          'tester' => 'schinder@pobox.com'
        };
$VAR1 = {
          'version' => '0.1004',
          'date' => '199908281230',
          'dist' => 'HTML-EP-Explorer',
          'osvers' => '10.20',
          'state' => 'pass',
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'postdate' => '199908',
          'platform' => 'PA-RISC1.1',
          'id' => 13,
          'guid' => '00000013-b19f-3f77-b713-d32bba55d77f',
          'type' => 2,
          'tester' => 'schinder@pobox.com'
        };
