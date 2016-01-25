#!/usr/bin/perl

use utf8;
use open ':utf8';
use Data::Dumper;
use XML::LibXML;

binmode STDOUT, ":encoding(UTF-8)";

my $parser = XML::LibXML->new();

my $f = $parser->parse_file('all.kml') or die;

$rootel = $f -> getDocumentElement();

#&dodo($rootel);
process_node($rootel);


sub process_node {
  my $node = shift;

#  print $node->nodePath, "\n";
  print $node->getName . " " . $node->getValue . "\n";
  if ($node->getName eq "Placemark") {
    my %h;
    print "got Placemark\n";
    for my $child ($node->childNodes) {
      $n = $child->getName;
      $v = $child->textContent;
      $v =~ s/[ \n\t]//g;
#    print "--$n,$v--\n";
      $h{$n} = $v;
    }
    print $h{name}." at ".$h{Point}." end\n";
    
  } else {
    for my $child ($node->childNodes) {
        process_node($child);
    }
  }
}
# documentElement is more straight-forward than findnodes('/').

sub dodo()
{

my $rootel = shift;

$elname = $rootel -> getName();
@kids = $rootel -> childNodes();

print "Root element is a $elname and it contains ...\n";

foreach $child (@kids) {
        $elname = $child -> getName();
        @atts = $child -> getAttributes();
        print "$elname (";
        foreach $at (@atts) {
                $na = $at -> getName();
                $va = $at -> getValue();
                print " ${na}[$va] ";
                }
        print ")\n";
        @x = $child -> childNodes();
        print "number of childs " . $x . ".\n";

        if ($x != 0 and $x ne "") {
          &dodo($child);
        }
}
}

die;
$Data::Dumper::Indent = 1;
#print Dumper $f;

print"\n";


&x($f->{kml}->{Document});

sub placemark()
{
  my $p = shift;

  foreach $i (keys %{$p})
  {
    print "p $i = ". $p->{$i} . "\n";
  }
  print $p->{Point}->{coordinates} . "\n";
  print $p->{name} . "\n";
}

sub x()
{
  my $f = shift;
  foreach $i (keys %{$f})
  {
    print "f: $i = ". $f->{$i} . "\n";
    if ($i eq "Folder") {
      &x($f->{$i});
    }
    if ($i eq "Placemark") {
      &placemark($f->{Placemark});
    }
  }
}


