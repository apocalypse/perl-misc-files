#!/usr/bin/perl
use strict; use warnings;

#sub Test::Reporter::POEGateway::DEBUG () { 1 }

use Test::Reporter::POEGateway;

# let it do the work!
Test::Reporter::POEGateway->spawn();

# run the kernel!
POE::Kernel->run();
