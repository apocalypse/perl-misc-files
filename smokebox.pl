#!/usr/bin/perl
use strict; use warnings;

use POE;
use POE::Component::SmokeBox;
use POE::Component::SmokeBox::Smoker;
use POE::Component::SmokeBox::Job;

use Data::Dumper;

# autoflush
$|++;

my $smokebox = POE::Component::SmokeBox->spawn();

POE::Session->create(
	package_states => [
		'main' => [ qw(_start _stop _results) ],
	],
);

$poe_kernel->run();
exit 0;

sub _start {
	# get the available perl versions
	my $perls = getPerlVersions();
	foreach my $p ( @$perls ) {
		my $smoker = POE::Component::SmokeBox::Smoker->new(
			perl => "$ENV{HOME}/perls/$p/bin/perl",
			env => {
				'APPDATA' => "$ENV{HOME}/cpanp_conf/$p/",
			},
		);
		$smokebox->add_smoker( $smoker );
	}

	# Add system perl...
	# Configuration successfully saved to CPANPLUS::Config::User
	#    (/home/apoc/.cpanplus/lib/CPANPLUS/Config/User.pm)
	my $perl = `which perl`; chomp $perl;
	$smokebox->add_smoker( POE::Component::SmokeBox::Smoker->new(
		perl => $perl,
		env => {
			'APPDATA' => "$ENV{HOME}/",
		},
	) );

	# test a smoke run
	foreach my $m ( qw( Acme::Drunk Acme::24 ) ) {
		$smokebox->submit( event => '_results',
			job => POE::Component::SmokeBox::Job->new(
				command => 'smoke',
				module => $m,
				type => 'CPANPLUS::YACSmoke',
			),
		);
	}
	return;
}

sub _stop {
	$smokebox->shutdown();
	return;
}

sub _results {
	my $results = $_[ARG0];
print Dumper( $results );

	# TODO report this to IRC

	# TODO remove all .cpanplus/build cruft

	return;
}

# gets the perls
sub getPerlVersions {
	my @perls;
	opendir( PERLS, "$ENV{HOME}/perls" ) or die "unable to opendir: $@";
	@perls = grep { /^perl\-/ && -d "$ENV{HOME}/perls/$_" && -e "$ENV{HOME}/perls/$_/ready.smoke" } readdir( PERLS );
	closedir( PERLS ) or die "unable to closedir: $@";

	return \@perls;
}
