#!/usr/bin/perl
use strict;
use JSON;
use Data::Dumper;
use Encode;

$\ = "\n";
$, = ",";

if (@ARGV <1){
        print <<EOM;
USAGE:  $0 list.csv

Convert a IOC multiling list (saved as ut8 text encoding -- tab separeted values) to a json file
File must haven't BOM caracter
(Abrir com o excel e guardar em unicode txt. Depois abrir com o notepad++ e converter para utf8 without BOM)
EOM
        exit;
}

my $json = (new JSON)->utf8();
my $tmp = <>; #read firt line
$tmp =~ s/(\r|\n)+$//;
#my @oddNames = split /\t/, decode('utf8',$tmp);
my @oddNames = split /\t/, $tmp;
my $oddInit = 0;
#search the first colums of odd lines
while($oddNames[++$oddInit] !~ /Scientific/ && $oddInit < $#oddNames){};
3 == $oddInit || die "Unpexpected start (column $oddInit) of odd lines";
$tmp = <>; #read second line
$tmp =~ s/(\r|\n)+$//;
my @evenNames = split /\t/, $tmp;
my $evenInit = 0;
#search the first colums of even lines
while($evenNames[++$evenInit] !~ /English/ && $evenInit < $#evenNames){};
4 == $evenInit || die "Unpexpected start (column $evenInit) of even lines";
#print=  $page;
my $r = {};
my $ordo;
my $familia;
my $sciname;
my $vernacularNames;
my $pos = 0;
while (<>){
	s/(\r|\n)+$//;
	my @names = split /\t/,decode('utf8',$_);
	if ($names[1] ne ''){
		$ordo = $names[1];
		next
	}elsif ($names[2] ne ''){
		$familia = $names[2];
		next;
	}elsif ($names[3] ne ''){
		$sciname = $names[3];
		$vernacularNames = {};
		for(my $i = 5; $i <=  $#oddNames; $i+=2){
			$vernacularNames->{$oddNames[$i]} = $names[$i];
		}
		next;
	}elsif($names[4] ne ''){
		for(my $i = 4; $i <=  $#evenNames; $i+=2){
			$vernacularNames->{$evenNames[$i]} = $names[$i];
		}
		my ($genus,$species) = split / /, $sciname;
		$r->{$sciname} = {
			ordo => $ordo,
			familia => $familia,
			genus => $genus,
			species => $species,
			vernacularNames => $vernacularNames,
			position => ++$pos 
		};
		$vernacularNames = undef;
		$sciname = undef;
	}else{
		print STDERR "Unexpected line:$_\n";
	}
}
print $json->pretty->encode($r);
