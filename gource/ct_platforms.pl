#!/usr/bin/perl
use strict; use warnings;

# This script takes the cpanstats DB and outputs it into a format
# that Gource likes. This script specifically outputs the graph of
# all perl versions/platforms tested.

# Grab the cpanstats DB from http://devel.cpantesters.org/cpanstats.db.bz2
#	NOTE: it is recommended that you do: sqlite> CREATE INDEX ixdate2 ON cpanstats (date);
# Get the cpantesters mapping from a magic fairy ;)

# Warning: the resulting log will be ~800M as of March 20, 2010!
# -rw-r--r-- 1 apoc apoc 797M 2010-03-20 23:47 ct_platforms.log

# TODO use Term::ProgressBar and calculate the total number of rows + update the term...

# some misc configs
my $cpanstats = '/home/apoc/gource_ct/cpanstats.db';
my $cpan_map = '/home/apoc/gource_ct/cpantesters_mapping.txt';

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
	my $sth = $dbh->prepare( 'SELECT tester, platform, perl, osname, osvers, date FROM cpanstats ORDER BY date' );
	$sth->execute;
	my $newdata;
	$sth->bind_columns( \( @$newdata{ @{ $sth->{'NAME_lc'} } } ) );

	# Start with the header
	# set the date as 935820000 which is right before id 1 in the DB :)
	print "user:APOCAL\n935820000\n:000000 100644 0000000... AAAAAAA... A	/\n\n";

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
			# We want to get PAUSE ids only
			if ( $name =~ /\(([^\)]+)\)$/ ) {
				$cpantesters_map{ $email } = $1;
			} else {
				$cpantesters_map{ $email } = $name;
			}
		}
	}
}

sub find_cpantesters_map {
	my $email = shift;

	# Sanity
	return 'UNKNOWN@UNKNOWN' if ! defined $email or ! length $email;
	if ( exists $cpantesters_map{ $email } ) {
		return $cpantesters_map{ $email };
	} else {
		# We want to get PAUSE ids only
		if ( $email =~ /\(([^\)]+)\)$/ ) {
			return $1;
		} else {
			return $email;
		}
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
	$report{platform} = 'UNKNOWN' if ! defined $report{platform} or ! length $report{platform};
	$report{osname} = 'UNKNOWN' if ! defined $report{osname} or ! length $report{osname};
	$report{osvers} = 'UNKNOWN' if ! defined $report{osvers} or ! length $report{osvers};
	$report{perl} = 'UNKNOWN' if ! defined $report{perl} or ! length $report{perl};
	$report{perl} = 'UNKNOWN' if length $report{perl} == 1;	# to shut up perl = 0 reports...

	# Generate the git output!
	my $output = "user:$report{tester}\n";
	$output .= $report{date} . "\n";

	# git output is:
	#:000000 100644 0000000... bd3b6ca... A	poe/lib/POE/Kernel.pm
	#:000000 100644 0000000... 83c9f1a... A	poe/lib/POE/Session.pm
	#:100644 100644 bd3b6ca... 63d6c22... M	poe/lib/POE/Kernel.pm
	#:(old file mask - 0 if A) (new file mask - 0 if A) (parent guid - 0 if A) (new guid) (mode - A for add, M for modify) (path)
	# Make the graph easier to see by putting the ver/platform as the filename
	if ( exists $tree{ $report{perl} }{ $report{osname} }{ $report{platform} } ) {
		# This perl/platform was already submitted

		$output .= ":100644 100644 AAAAAAA... AAAAAAA... M\t/$report{perl}/$report{osname}/v$report{perl} $report{osname} ($report{platform})\n";
	} else {
		# New perl/platform

		$output .= ":000000 100644 0000000... AAAAAAA... A\t/$report{perl}/$report{osname}/v$report{perl} $report{osname} ($report{platform})\n";
		$tree{ $report{perl} }{ $report{osname} }{ $report{platform} } = 1;
	}
	$output .= "\n";

	print $output;
	return;
}

__END__

# to generate the video, run this script and save the log:
perl ct_platforms.pl > ct_platforms.log

# Then run Gource like this:
gource ct_platforms.log -1280x720 --highlight-all-users --multi-sampling \
  --disable-bloom --elasticity 0.0001 --max-file-lag 0.000001 --max-files 10000 \
  --date-format "CPANTesters Reports For Platforms On %B %d, %Y %X" --stop-on-idle --file-idle-time 1000 \
  --user-friction 0.0000001 --seconds-per-day 0.000001 --hide dirnames --camera-mode overview \
  --user-image-dir gravatars/ \
  --output-ppm-stream - | ffmpeg -y -b 10000K -r 100 -f image2pipe -vcodec ppm -i - -vcodec mpeg4 gource_CT_platforms.mp4

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
          'perl' => '0',
          'osname' => '',
          'date' => 935824080,
          'id' => 1,
          'platform' => '',
          'tester' => 'ABH',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935825520,
          'id' => 2,
          'platform' => '',
          'tester' => 'KWILLIAMS',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935837940,
          'id' => 3,
          'platform' => '',
          'tester' => 'ABH',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935843880,
          'id' => 4,
          'platform' => '',
          'tester' => 'EGROSS',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '0',
          'osname' => '',
          'date' => 935844600,
          'id' => 5,
          'platform' => '',
          'tester' => 'MADWOLF',
          'osvers' => ''
        };
$VAR1 = {
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'date' => 935842440,
          'id' => 6,
          'platform' => 'sun4-solaris',
          'tester' => 'schinder@pobox.com',
          'osvers' => '2.7'
        };
$VAR1 = {
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'date' => 935842500,
          'id' => 7,
          'platform' => 'PA-RISC1.1',
          'tester' => 'schinder@pobox.com',
          'osvers' => '10.20'
        };
$VAR1 = {
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'date' => 935842740,
          'id' => 9,
          'platform' => 'PA-RISC1.1',
          'tester' => 'schinder@pobox.com',
          'osvers' => '10.20'
        };
$VAR1 = {
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'date' => 935842920,
          'id' => 12,
          'platform' => 'sun4-solaris',
          'tester' => 'schinder@pobox.com',
          'osvers' => '2.7'
        };
$VAR1 = {
          'perl' => '5.4.4',
          'osname' => 'hpux',
          'date' => 935843400,
          'id' => 13,
          'platform' => 'PA-RISC1.1',
          'tester' => 'schinder@pobox.com',
          'osvers' => '10.20'
        };
$VAR1 = {
          'perl' => '5.5.3',
          'osname' => 'solaris',
          'date' => 935843400,
          'id' => 14,
          'platform' => 'sun4-solaris',
          'tester' => 'schinder@pobox.com',
          'osvers' => '2.7'
        };
