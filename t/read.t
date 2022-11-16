#!/usr/bin/env perl
use strict; use warnings;
use Test::Simple 'no_plan'; # tests=>0;
use App::AFNI::SiemensPhysio;


my $p = App::AFNI::SiemensPhysio->new({
          VERB=>1,
          MRDiscardNum=>0,
          prefix=>'NA',
          nDcms=>220,
          trustIdx=>'MR'});
$p->readBIDSJson('./data/7t/sub-11821_task-rest_run-01_bold.json');

ok($p->{MRstart} == 16*60*60 + 49*60 +12.522500);
