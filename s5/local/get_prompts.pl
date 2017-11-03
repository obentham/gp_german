#!/usr/bin/perl -w
# get_prompts.pl - make  a prompts file

use strict;
use warnings;
use Carp;

BEGIN {
    @ARGV == 1 or croak "USAGE: get_prompts.pl <FOLD>
$0 dev
";
}

use File::Basename;

my ($fld) = @ARGV;

my $tmpdir = "data/local/tmp/gp/german";
my $o = "$tmpdir/$fld/prompts.tsv";
my $l = "$tmpdir/$fld/lists/trl.txt";

open my $L, '<', "$l" or croak "$l $!";

open my $O, '+>', "$o" or croak "problems with $o  $!";

while ( my $line = <$L> ) {
    chomp $line;
    my $d = dirname $line;
    my $b = basename $line, ".trl";

    system "iconv \\
-f ISO_8859-1 \\
-t utf8 \\
$line \\
> \\
$d/$b.txt";

    open my $T, '<', "$d/$b.txt" or croak "problems with $d/$b.txt $!";
    my $spkr = "";
    my $sn = 0;
    LINE: while ( my $linea = <$T> ) {
	chomp $linea;
	next LINE if ( $linea =~ /^$/);

	if ( $linea =~ /^\;SprecherID\s(\d{1,3})/ ) {
	    $spkr = $1;
	} elsif ( $linea =~ /^\;\s(\d{1,})/ ) {
	    my $n = $1;
	    print $O "GE${spkr}_${n}.adc\t";
	} else {
	    print $O "$linea\n";
	}      
    }
    close $T;
}
close $O;
