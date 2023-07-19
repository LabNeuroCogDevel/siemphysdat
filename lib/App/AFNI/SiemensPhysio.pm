#!/usr/bin/env perl

package App::AFNI::SiemensPhysio;
use strict; 
use warnings;
use Carp;
use List::MoreUtils qw/minmax uniq/;
use File::Basename;
use File::Copy 'mv';
use feature 'say';


=pod 

=head1 NAME
 
App::AFNI:SiemensPhysio - Physio from Siemens into format suitable for AFNI's RetroTS retroicor routine

=head1 SYNOPSIS

Get slice based respiration volume per time (RVT) regressors from physio collected on Siemens scanner

  my $p = SiemensPhysio->new({VERB=>1});
  # read MR data (get times, TR, nslices)
  #  looks at all files in this directory with "dicom_hinfo"
  $p->readMRdir('MRRaw/10824_20111108/rest_384x384.21/');

  # read pulse
  $p->readPhysio('10824/20111108/wpc4951_10824_20111108_110811.puls');
  # write card: $protocol_$sessionTime.puls.dat
  $p->writeMRPhys;

  # read card
  $p->readPhysio('10824/20111108/wpc4951_10824_20111108_110811.resp');
  # write resp: $protocol_$sessionTime.resp.dat
  $p->writeMRPhys;

  # 
  $p->retroTS('matlab')

  # we could get the raw data 
  #   in this case, card was resp was loaded last
  #   thats what will be returned)
  my @pval = $p->getMRPhys();

=head1 DESCRIPTION



=head2 Pipeline

=over

=item read Siemens physio files

=item read timing from MR DICOM files

=item snip physio files relative to MR 

=item prepare/run AFNI's RetroTS

=back


=head2 prior art


=over 

=item  https://cfn.upenn.edu/aguirre/public/exvolt/

=item https://cfn.upenn.edu/aguirre/wiki/public:pulse-oximetry_during_fmri_scanning

=back

=cut



=head2 new

initialize object

=head3 OPTIONS

=over

=item timetype

MDH (default) or MPCU

=item PhRate 

Physio sample rate
defaults to .2

=item pulsStart and respStart
numeric sequence to be remove, also identifies stream type

defaults:

  pulsStart =>'1 2 40 280'
  respStart =>'1 2 20 2'


=item sliceOrder

alt+z (default)
other options: alt-z,seq+z,seq-z,filename # slice order

=item VERB

set to true to be verbose, defaults false

=item trustIdx

don't check sample rate and index count against end-start time
  none=> check both
  MR  => trust MR (TR)
  phys=> trust physio (PhRate as set by init)
  all => trust both

Note: trust assinged by reg exp, 'MR+phys' is same as 'all'

=back 

=cut

sub new {
  my $class = shift;
  my $self  = shift;
  # default to MDH becaues MPCPU doesn't align to MR time
  my %defaults = (
   #run       => 'matlab', # matlab|McRetroTs|none
   timetyp   => 'MDH',    # MPCU|MDH

   PhRate =>'.02',
   # parameters of the acquisition. 
   # third is ticktime, but unlcear what the transfor is to get to freq/samplerate
   pulsStart =>'1 2 40 280',
   respStart =>'1 2 20 2',
   sliceOrder => 'alt+z',
   MRDiscardNum => 0, # how many MR volues to discard
   VERB=>0,
   trustIdx=>'none',
   changeTR=>0,
   changeNDcms=>0,
  );
  # use defaults when we didn't set anything
  for my $k (keys %defaults) {
    $self->{$k} = $defaults{$k} unless $self and $self->{$k};
  }

  return bless $self, $class;
}

sub idxTR {
   my @measures = @_;
   my @acc_i = ();
   for my $i (0..$#measures) {
       # -2 b/c want before and $# == 0 if 1 element
       # if 5000 is first, call idx -1
       push @acc_i, ($i - $#acc_i -2) if($measures[$i] == 5000);
   }
   return @acc_i;
}

=head2 readPhysio

after intializing p, provide a file name

 $p->readPhysio('10824/20111108/wpc4951_10824_20111108_110811.puls');

=head3 input file format

 1 2 40 280 ... [long space delimn. list of measurements, maybe 5000 for trigger?]
 ECG  Freq Per: 0 0
 PULS Freq Per: 74 807
 RESP Freq Per: 20 2860
 EXT  Freq Per: 0 0
 ECG  Min Max Avg StdDiff: 0 0 0 0
 PULS Min Max Avg StdDiff: 527 1586 828 4
 RESP Min Max Avg StdDiff: 2380 6700 3477 86
 EXT  Min Max Avg StdDiff: 0 0 0 0
 NrTrig NrMP NrArr AcqWin: 0 0 0 0
 LogStartMDHTime:  66439690
 LogStopMDHTime:   71116595
 LogStartMPCUTime: 66439512
 LogStopMPCUTime:  71114802
 6003

=cut

sub readPhysio {
   my $self=shift;
   my $fname=shift;

   croak "cannot open $fname" 
     unless $fname and open my $fh, '<', $fname;

   my $pulsStart = $self->{pulsStart};
   my $respStart = $self->{respStart};
   my $timetyp   = $self->{timetyp};

   # first line is physio measures
   # puls and resp have unique start sequences
   my $values = <$fh>;

   croak "$fname does not start with expected resp or pulse prefix sequence values" 
     unless $values=~s/^((?<puls>$pulsStart)|(?<resp>$respStart))\W*//;

   # we can get the type by which regex we matched
   $self->{ptype}  = join('',map { $+{$_}?$_:"" } qw/puls resp/);

   # break values by whitespace, remove 5000 and above
   # 5000 is a scanner trigger, 5003 is end
   $self->{raw_measures} = [ split(/\W+/,$values) ];
   $self->{measures} = [ grep { $_ < 5000 } @{$self->{raw_measures}} ];

   # index where scanner TR is recordded (value=5000)
   $self->{idxTR} = [idxTR(@{$self->{raw_measures}})];

   # get settings matching 
   my %settings;
   while($_=<$fh>){
    # remove dos chars
    s///g; 

    # parse settings, primarily for start and end time
    $settings{$1} = $2 if m/(.*):\W+(.*)/; 

    # check file integrity; assume last line is 6003
    croak "corrupt file $fname. does not end with 6003" 
      if eof and ! m/^6003$/;
    
   }



   # get start and end from settings
   if(!$settings{"LogStart${timetyp}Time"} or !$settings{"LogStop${timetyp}Time"}) {
     croak "Cannot find Log(Start|Stop)*Time in $fname";
   }

   $self->{physStart} = $settings{"LogStart${timetyp}Time"}/1000;
   $self->{physEnd}   = $settings{"LogStop${timetyp}Time"}/1000;



   
   # reset rate if its only off by a very small amount
   # and we don't trust the sample rate we provided
   # TODO: this could be a function of the nt*tr/lenght of sequence
   my $newrate = abs($self->{physStart}- $self->{physEnd})/$#{$self->{measures}};
   $self->{PhRate} = $newrate 
     if abs($newrate-$self->{PhRate}) < .0001  and
        $self->{trustIdx}!~/All|Phys/i;


   say "file is $self->{ptype} with $#{$self->{measures}} samples, " ,
       "$self->{physStart}s - $self->{physEnd}s (",
       sprintf("%.2f",($self->{physEnd}-$self->{physStart})/60),
       "min), sample rate adjusted to $self->{PhRate}"
     if $self->{VERB};

   # does the time match the sample rate and number of samples
   timeCheck($self->{physStart},
             $self->{physEnd},
             $#{$self->{measures}},
             $self->{PhRate} ) unless $self->{trustIdx}=~/All|Phys/i;

   # re/set MR within Phys indexes
   $self->setMRidx();
}


=head2 readMRdir

after intializing p, read in MR info from raw DICOM directory

  $p->readMRdir('MRRaw/10824_20111108/rest_384x384.21/');

sets 

=over

=item timing (MRstart and MRend)

=item protcol info (protocol,TR,ET,nslices,Series)

=back

=head3 Example Info

dicom header info

  dicom_hdr MRRaw/10824_20111108/rest_384x384.21/MR* |egrep 'protocol|acquisition Time|Echo Time|Repetition Time' -i
    0008 0031       14 [620     ] //                 ID Series Time//164627.359000
    0008 0032       14 [642     ] //            ID Acquisition Time//164932.315000 
    0018 0080        4 [1418    ] //            ACQ Repetition Time//1500
    0018 0081        2 [1430    ] //                  ACQ Echo Time//29
    0018 1030        4 [1612    ] //              ACQ Protocol Name//rest
    0019 100a        2 [1788    ] //                               // 29

shortend to

  dicom_hinfo -tag 0008,0032 0008,0031 0018,0080 0018,0081 0018,1030 MR*

=cut 

# sets MRstart MRend protocol TR ET protocol nslices Series
sub readMRdir {
 my $self=shift;
 my $dicomdir=shift;
 croak "$dicomdir is not a directory!" if ! -d $dicomdir;
 my $dcmcmd = "dicom_hinfo -tag 0008,0031 0008,0032 0018,0080 0018,0081 0018,1030  0019,100a $dicomdir/*";
 our @returns =     qw/Filename   Series    AcqTime       TR        ET     protocol nslice/;
 # N.B.  nslices/"Number Of Images In Mosaic" (0019,100a) is Siemens specific
 # which is okay, because thats the kind of physio we have


 # the index at which we can find the item we want
 sub getidx {
  my $name=shift;
  return (grep { $returns[$_] eq $name } (0..$#returns))[0];
 }

 # @v is an element for each dcm (line of output)
 my @v=`$dcmcmd` or croak "could not run $dcmcmd";


 # make each line an array
 # so we have an array of arrays
 # v[0] is all info on first dicom
 # v[0][0] is the first dicom's file name
 @v= map { [split / /] } @v;
 
 # Sort by acq time (just in case file names are out of order)
 # only needed to ensure trunction takes out the right dicoms
 my $ati=getidx('AcqTime');
 @v = sort {$a->[$ati] <=> $b->[$ati]} @v;

 # Truncate dicom list if we have volumes to discard
 # for some multi-band protocols, the first dicom is junk
 # for older protocols, we have to manually discard volumes
 #  -- eitherway we dont want them
 @v=@v[($self->{MRDiscardNum})..$#v] if($self->{MRDiscardNum});

 # record some constant settings/values
 for my $vals (qw/protocol TR ET Series nslice/) {
    my $vidx=getidx($vals);
    # make sure it's constant
    my @allvals = uniq(map {$_->[$vidx]} @v);
    croak "$vals is not constant: ".join(",",@allvals) if $#allvals>0;

    chomp($allvals[0]);
    $self->{$vals} = $allvals[0];
 }
 $self->{nDcms} = $#v+1;
 $self->{TR} /=1000;
 

 ## changes to what we should have gotten from dicom header
 my $mr_tr_s = $self->{changeTR};
 if($mr_tr_s != 0){
   warn "manually setting tr to $mr_tr_s is not necessary" if($mr_tr_s == $self->{TR});
   say "# manually adjusting tr from '$self->{TR}' to '$mr_tr_s'";
   $self->{TR} = $mr_tr_s;
 } else { say "# keeping orig tr $self->{TR}";}

 if($self->{changeNDcms}>0){
   say "# manually adjusting nVols from '$self->{nDcms}' to '$self->{changeNDcms}'";
   $self->{nDcms} = $self->{changeNDcms};
 }
 


 # Acquistion index
 my $ATidx= getidx('AcqTime');

 # find max and min acq time from all MR*s
 my ($starttime, $endtime) = minmax( map {$_->[$ATidx] } @v);


 ## set start and end
 $self->{MRstart} = getMRAcqSecs($starttime);
 $self->{MRend}   = getMRAcqSecs($endtime);

 say "MR starts $self->{MRstart} (DICOM $starttime) and ends $self->{MRend} (DICOM $endtime)"
   if $self->{VERB};

 timeCheck($self->{MRstart},
           $self->{MRend},
           $self->{nDcms},
           $self->{TR}) unless $self->{trustIdx}=~/All|MR/i;
}

=head2 readBIDSJson
read TR MRstart and crate MRend from BIDS style json output 
(e.g. created by dcm2niix). 

must already have nDcms (number of volumes in 4d) set

=cut
sub readBIDSJson() {
 use JSON qw/decode_json/;
 my $self=shift;
 my $jsonfile=shift;
 open my $JS, '<', $jsonfile or 
   croak "could not open BIDS JSON '$jsonfile'";
 my $data = decode_json(do{local $/; <$JS>})  or
   croak "could not parse JSON in '$jsonfile'";

 $self->{'MRstart'} = getMRAcqSecs($data->{'AcquisitionDateTime'}||$data->{'AcquisitionTime'});
 # ($+{HH}*60*60) + ($+{MM}*60) + $+{SS} ..
 $self->{TR} = $data->{RepetitionTime}; # in seconds. eg 1.5
 $self->{MRend} = $self->{MRstart} + $self->{nDcms}*$self->{TR};
 # timeCheck is meaningless -- MRend is derived the same way as the check
           
 # for output, set protocol and series 
 $self->{protocol} = $data->{ProtocolName};
 $self->{Series} = $data->{SeriesDescription};
 # Also have meaningful attributes
 # PhaseEncodingDirection SliceTiming
}

=head2 writeMRPhys

write phys during MR to file
works on most recently loaded physio file

  $p->writeMRPhys

=over 

=item use getMRphys to get values 

=item use writeDat to write values

=back

=cut

sub writeMRPhys {
 my $self=shift;
 my $outfile = shift;
 $outfile="$self->{protocol}_$self->{Series}.$self->{ptype}.dat" if ! $outfile;
 
 # if we provided a prefix
 if($self->{prefix}){
   # get dir
   my $bn=dirname($self->{prefix});
   croak "prefix directory ($bn) does not exist!" if ! -d $bn;
   $outfile=$self->{prefix}.$outfile;
 }

 $self->{dat}->{$self->{ptype}}=$outfile;
 my @pvals = $self->getMRPhys;

 say "saving to $outfile" if $self->{VERB};
 writeDat($outfile,@pvals)
}

sub meandiff {
   my @a=@_;
   my $sum=0;
   for(1..$#a){ $sum+=$a[$_]-$a[$_-1];}
   return $sum/$#a;
}

=head2 checkTRfreq
Use count of '5000' in sequence to check sample frequence and TR
=cut
sub checkTRfreq {
   my $self=shift;
   my $start = $self->{'MRstartIdx'};
   my $end = $self->{'MRendIdx'};
   #say "#s $start, e $end, n: $self->{nDcms}";
   my @trs = grep {$_ >= $start && $_ <= $end} @{$self->{idxTR}};

   my $tr_samprate = meandiff @trs;
   print "# avg num samples between pulses: $tr_samprate => ",
$tr_samprate*$self->{PhRate},"s TR\n";
   # not a good check!
   # demo data: 4573 5000s in puls, instead of 200!?
   carp "MR nVols mismatch: $self->{nDcms} != $#trs trigger=5000 in '$self->{ptype}' (phys idx $start and $end)" if
      $#trs != $self->{nDcms};
}



=head2 retroTS

This is kludgy code hacked together and untested :)
=over

=item use a bunch of hacks to find the matlab binary

=item construct a matlab call using options in self object

=item execute matlab or McRetroTS 

=item move outputs to fit local naming convention

=back



get/run command to get Resp. Vol./Time (RVT) via AFNI's retroTS a la http://www.ncbi.nlm.nih.gov/pmc/articles/PMC2715870/
MUST have already read MR and written card and resp dat files

  $p->retroTS('matlab')

how this step is handled is defined by the first argument



=over

=item matlab: use RetroTS.m

=item McRetroTs: use compiled matlab verson of RetroTS.m

=item show: print commands for both matlab and McRetroTS

=item none: do nothing (why'd you call me then!?)

=back


=head3 External Commands

see  

=over

=item http://afni.nimh.nih.gov/afni/matlab/

=item http://afni.nimh.nih.gov/sscc/dglen/McRetroTS

=item http://fieldtrip.googlecode.com/svn/trunk/external/afni/RetroTS.m

=back

if using matlab+retroTS, the path to retroTS.m should be in your MATLABPATH
  export MATLABPATH="$HOME/afni_matlab/matlab/:$MATLABPATH"

=cut


sub retroTS {
 my $self=shift;
 my $runtype=shift;
 return if $runtype and $runtype =~ /none/i;

 # we need to have both data types
 croak "need writeMRPhys for both puls and resp" 
   if ! $self->{dat} || ! -e $self->{dat}->{resp} || ! -e $self->{dat}->{resp};


 # default to using matlab
 my $matlabbin="matlab";

 # find where matlab script points to
 #my $acutalmatlab=`perl -ne 'print \$& if /^.*matlab /' \`which matlab\``;
 #$matlabbin=$acutalmatlab if $acutalmatlab;

 # or use env MATLABBIN
 $matlabbin= $ENV{MATLABBIN} if $ENV{MATLABBIN};


 my %params = (
   "Opts.Respfile"   => "'".$self->{dat}->{resp}."'", # Respiration data file
   "Opts.Cardfile"   => "'".$self->{dat}->{puls}."'", # Cardiac data file
   "Opts.PhysFS"     => 1/$self->{PhRate},    # Physioliogical signal sampling frequency in Hz.
   "Opts.Nslices"    => $self->{nslice},      # Number of slices
   "Opts.VolTR"      => $self->{TR},          # Volume TR in seconds
   "Opts.SliceOrder" => "'".$self->{sliceOrder}."'"  # ['alt+z']/'alt-z'/'seq+z'/'seq-z'/'Custom'/filename.1D
 );

 # McRetroTS Respdatafile ECGdatafile VolTR Nslices SamplingFreq(PhysFS) ShowGraphs
 my @mcrts = qw/Opts.Respfile Opts.Cardfile Opts.VolTR Opts.Nslices Opts.PhysFS/;
 my $mccmd =  "McRetroTs @params{@mcrts}";
 say $mccmd if $runtype !~ /matlab|McRetroTs/g ;;


 # if have matlab and singal toolbox, can use this
 my $cmd = join("; ", map { join("=",$_,$params{$_}) } keys %params);
 $cmd .= "; Opts.ShowGraphs=0;Opts.Quiet=0;"; # turn off graphs, turn on verbose
 $cmd .= " rts = RetroTS(Opts)";

 # we should wrap matlab up in a try+quit so we dont hang in ML command window on a failure
 my $matlabwrap= qq/$matlabbin -nodisplay -r "try; $cmd; catch err; err, exit(1); end; rts, quit;"/;

 say $matlabwrap if $runtype !~ /matlab|McRetroTs/i;
 # eg
 # matlab -nodisplay -r "try; Opts.Cardfile='rest_164627.359000.puls.dat'; Opts.VolTR=1.5; Opts.Nslices=29; Opts.SliceOrder='alt+z'; Opts.PhysFS=50.0074711455304; Opts.Respfile='rest_164627.359000.resp.dat'; rts = RetroTS(Opts); catch; exit(666); end; quit;"

 # with either command, the original output name will be "oba.slibase.1D"
 # change that to our basename (assume resp and puls have same basename, use one from resp)
 my $outputname = $self->{dat}->{resp};
 $outputname =~ s/.resp.dat$/.slibase.1D/;
 
 # or rename to specified input
 #my $outputname=shift if $#_;
 
 
 my $runcmd="";
 if($runtype =~ /matlab/i){
  $runcmd=$matlabwrap
 }elsif($runtype =~ /McRetroTs/i){
  $runcmd=$mccmd;
 }


 if($runcmd) {
   # retroTS just dumpes out oba.slibase.1D whereever it is run from
   # ..so run from where we want to save the file
   chdir dirname($outputname); 
   system($runcmd);

   # check if we have the expected output
   if(! -e "oba.slibase.1D" ){
     croak "failed to run\n\n: $runcmd\n\n";
   } else {
     # move file to output name
     mv "oba.slibase.1D", $outputname or
        croak "could not move oba.slibase.1D to $outputname";
   }
   print "$outputname # saved as final output " , `date +%F\\ %H:%M` , "\n";
 }


}



#################
#### helpers ####
#################


# do start end and tr times make sense?
sub timeCheck {
 my ($start,$end,$n,$tau) = @_;

 #my $maxDiffSec=$tau*2;
 my $maxDiffSec=$tau;
 my $dur=$end-$start;
 my $ideal=$n *$tau;

 # start and end time are sane
 croak "time starts ($start) before or on end time ($end)!" 
   if($end<=$start);

 # samples * sample rate == actual duration
 my $offby  = sprintf('%.3f',$ideal-$dur);
 my $offbyN = sprintf('%.0f',$offby/$tau);
 my $obsrate = $dur/$n;
 croak "total duration off by $offby s ($offbyN samples) > max $maxDiffSec diff: $n samples at $tau should be $ideal secs not $dur ($end - $start). Is sample rate actually $obsrate" 
   if(abs($offby) > $maxDiffSec);

 return 1;
}

# DICOM Acq Time is fmt like HHMMSS.SS (172745.487500)
# JSON BIDs AcqTime like 2018-06-15T17:27:45.487500
# or "12:46:30.332500"
sub getMRAcqSecs {
  $_=shift;
  m/^(?<HH>\d{2}):?(?<MM>\d{2}):?(?<SS>\d{2}\.\d+)$/ or
   m/^\d{4}-\d{2}-\d{2}T(?<HH>\d{2}):(?<MM>\d{2}):(?<SS>\d{2}\.\d+)$/ or
   croak "timestr '$_' from MR does not look like HH:?MM:?SS.sssss or like YYYY-MM-DDTHH:MM:SS.sssss";

  my $secs = ($+{HH}*60*60) + ($+{MM}*60) + $+{SS} ;
  return $secs;
}


sub setMRidx {
 my $self=shift;
 my ($s,$e) = sandwichIdx( 
                    [@{$self}{qw/physStart physEnd/}], 
                    [@{$self}{qw/MRstart MRend/}], 
                    $#{$self->{measures}},
                    $self->{PhRate} );
 $self->{MRstartIdx} = $s;
 $self->{MRendIdx}   = $e;

 ## print out where data is coming from/how sandwiching worked
 $self->sayIndex if $self->{VERB};
}


# returns vector of phys for the timing of an MR file
sub getMRPhys {

 my $self=shift;
 my $s = $self->{MRstartIdx};
 my $e = $self->{MRendIdx};
 my @pval = @{$self->{measures}}[$s..$e];

 croak "no pvals!? bad indexes?" if $#pval < 0;
 return @pval;
}



# write values to file
sub writeDat {
 my ($outname,@pvals) = @_;
 croak "do not have a file name to save data" if(!$outname);
 croak "have 1 or fewer values to write"      if($#pvals < 1);

 open my $OH, '>', $outname or croak "could not open $outname to save physio";
 print $OH join("\n",@pvals);
 close $OH;
}

#
# get the start and end index of the 'MR in physio' (meat)
# given [start,end] time in seconds  of MR and [start,end] Physio (bread)
# need: start,end pairs in array ref + size and sample rate
#  sandwichIdx([physio start,end],[MR start, end], MRsize, PhSampleRate)
#
sub sandwichIdx {
  my ($bread, $meat, $n, $r) = @_;

  # make sure the meat is inside the bread
  my ($physStart,$physEnd) = @{$bread};
  my ($MRstart,$MRend)     = @{$meat};

  # MR times cannot be outside physio range
  croak sprintf("ERROR: MR starts ($MRstart) %.2f min before physio ($physStart)",
		($physStart-$MRstart)/60)
    if( $MRstart  < $physStart );

  croak sprintf("ERROR: MR ends ($MRend) %.02f min after physio ($physEnd)",
		($MRend-$physEnd)/60)
    if( $MRend  > $physEnd);

  # calc start and end by adding sandwitch top (start as ref)
  my $sIdxS = timeToSamples($bread->[0],$meat->[0],$r);
  my $eIdxS = timeToSamples($meat->[0] ,$meat->[1],$r ) + $sIdxS;

  # calc start and end by subt sandwitch bottom (use end as ref) 
  my $eIdxE = $n     - timeToSamples($bread->[1],$meat->[1],$r );
  my $sIdxE = $eIdxE - timeToSamples($meat->[0], $meat->[1],$r );

  my $total_mr_time=($eIdxS - $sIdxS)*$r;
  say "# calced: mr idx as $sIdxS to $eIdxS using ${r}Hz";
  say "# n=",($eIdxS - $sIdxS), " t=", $total_mr_time, "s";
  # are the two the same?
  carp "Inconsistant index calculation. ".
       "Using start time vs end time as ref grabs different sample of measurements\n".
       "(ref=start) $sIdxS to $eIdxS VS $sIdxE to $eIdxE (ref=end) @ $r secs/sample\n"
       if $sIdxS != $sIdxE || $eIdxS != $eIdxE;

  return ($sIdxS,$eIdxS);
}

# the diff of two times over the sampling rate gives the number of samples
sub timeToSamples {
  my ($start, $end, $rate) = @_;
  return  sprintf( '%.0f', abs($end - $start)/$rate ) ;
}

## print whats up
sub sayIndex {
 my $self=shift;

 # print out start and stop index for ps and pe
 my $ps = timeToSamples($self->{physStart},$self->{physStart},$self->{PhRate});
 my $pe = timeToSamples($self->{physStart},$self->{physEnd},$self->{PhRate});
 my $s  = $self->{MRstartIdx} || undef;
 my $e  = $self->{MRendIdx}   || undef;
 # lets talk about what we have
 say "# extracting MR window from Physio";
 say "# $ps        \t| MR $s    \t$e      \t| $pe  \t", $e-$s ," phys samps" if $s and $e;
 say "# $self->{physStart}\t| MR $self->{MRstart}\t$self->{MRend}\t| $self->{physEnd}\t",
      sprintf("%.03f", $self->{MRend} - $self->{MRstart})," secs";
 say "# MR: $self->{TR}s*$self->{nDcms}vol=",  $self->{TR}*$self->{nDcms}, "s total";
 say "# Ph for MR: ";
 say "# n=", $e-$s, "samples*",substr($self->{PhRate},0,6),"hz t=", ($e-$s)*$self->{PhRate}, "s";

}



1;


