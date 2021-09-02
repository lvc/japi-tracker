#!/usr/bin/perl
##################################################################
# Java API Tracker 1.3
# A tool to visualize API changes timeline of a Java library
#
# Copyright (C) 2015-2019 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
# PLATFORMS
# =========
#  Linux
#
# REQUIREMENTS
# ============
#  Perl 5 (5.8 or newer)
#  Java API Compliance Checker (2.4 or newer)
#  Java API Monitor (1.3 or newer)
#  PkgDiff (1.6.4 or newer)
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301  USA.
##################################################################
use Getopt::Long;
Getopt::Long::Configure ("posix_default", "no_ignore_case", "permute");
use File::Path qw(mkpath rmtree);
use File::Temp qw(tempdir);
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use Cwd qw(abs_path cwd);
use Data::Dumper;
use Digest::MD5 qw(md5_hex);

my $TOOL_VERSION = "1.3";
my $DB_NAME = "Tracker.data";
my $TMP_DIR = tempdir(CLEANUP=>1);

# Internal modules
my $MODULES_DIR = get_Modules();
push(@INC, dirname($MODULES_DIR));

# Basic modules
my %LoadedModules = ();
loadModule("Basic");
loadModule("Input");
loadModule("Utils");

my $JAPICC = "japi-compliance-checker";
my $JAPICC_VERSION = "2.4";

my $PKGDIFF = "pkgdiff";
my $PKGDIFF_VERSION = "1.6.4";

my $CmdName = basename($0);
my $ORIG_DIR = cwd();
my $MD5_LEN = 5;

my %ERROR_CODE = (
    "Success"=>0,
    # Undifferentiated error code
    "Error"=>2,
    # System command is not found
    "Not_Found"=>3,
    # Cannot access input files
    "Access_Error"=>4,
    # Cannot find a module
    "Module_Error"=>9
);

my $HomePage = "https://abi-laboratory.pro/";

my $ShortUsage = "API Tracker $TOOL_VERSION
A tool to visualize API changes timeline of a Java library
Copyright (C) 2019 Andrey Ponomarenko's ABI Laboratory
License: LGPLv2.1+

Usage: $CmdName [options] [profile]
Example:
  $CmdName -build profile.json

More info: $CmdName --help\n";

if($#ARGV==-1)
{
    printMsg("INFO", $ShortUsage);
    exit(0);
}

GetOptions("h|help!" => \$In::Opt{"Help"},
  "dumpversion!" => \$In::Opt{"DumpVersion"},
# general options
  "build!" => \$In::Opt{"Build"},
  "rebuild!" => \$In::Opt{"Rebuild"},
  "v=s" => \$In::Opt{"TargetVersion"},
  "t|target=s" => \$In::Opt{"TargetElement"},
  "clear!" => \$In::Opt{"Clear"},
  "clean-unused!" => \$In::Opt{"CleanUnused"},
  "confirm|force!" => \$In::Opt{"Confirm"},
  "global-index!" => \$In::Opt{"GlobalIndex"},
  "disable-cache!" => \$In::Opt{"DisableCache"},
  "deploy=s" => \$In::Opt{"Deploy"},
  "debug!" => \$In::Opt{"Debug"},
# other options
  "json-report=s" => \$In::Opt{"JsonReport"},
  "regen-dump!" => \$In::Opt{"RegenDump"},
  "rss!" => \$In::Opt{"GenRss"},
# private options
  "sponsors=s" => \$In::Opt{"Sponsors"}
) or ERR_MESSAGE();

sub ERR_MESSAGE()
{
    printMsg("INFO", "\n".$ShortUsage);
    exit($ERROR_CODE{"Error"});
}

my $HelpMessage="
NAME:
  Java API Tracker ($CmdName)
  Visualize API changes timeline of a Java library

DESCRIPTION:
  Java API Tracker is a tool to visualize API changes timeline
  of a Java library.
  
  The tool is intended for developers of software libraries and
  Linux maintainers who are interested in ensuring backward
  binary compatibility, i.e. allow old applications to run with
  newer library versions.

  This tool is free software: you can redistribute it and/or
  modify it under the terms of the GNU LGPL.

USAGE:
  $CmdName [options] [profile]

EXAMPLES:
  $CmdName -build profile.json

INFORMATION OPTIONS:
  -h|-help
      Print this help.

  -dumpversion
      Print the tool version ($TOOL_VERSION) and don't do
      anything else.

GENERAL OPTIONS:
  -build
      Build reports.
  
  -rebuild
      Re-build reports.
  
  -v NUM
      Select only one particular version of the library to
      create reports for.
  
  -t|-target TYPE
      Select type of the reports to build:
      
        apidump
        apireport
        pkgdiff
        changelog
        date
        graph
        compress
  
  -clear
      Remove all reports and API dumps.
  
  -clean-unused
      Remove unused reports and API dumps.
  
  -global-index
      Create list of all tested libraries.
  
  -disable-cache
      Enable this option if you've changed filter of checked
      symbols in the library (skipped classes, annotations, etc.).
  
  -deploy DIR
      Copy all reports and css to DIR.
  
  -debug
      Enable debug messages.

OTHER OPTIONS:
  -json-report DIR
      Generate JSON-format report for a library to DIR.
  
  -regen-dump
      Regenerate API dumps for previous versions if
      comparing with new ones.
  
  -rss
      Generate RSS feed.
";

my $Profile;
my $DB;
my $TARGET_LIB;
my $DB_PATH = undef;

# Sponsors
my %LibrarySponsor;

# Regenerate reports
my $ArchivesReport = 0;

# Report style
my $LinkClass = " class='num'";
my $LinkNew = " new";
my $LinkRemoved = " removed";

# Dumps
my $COMPRESS = "tar.gz";
my %DoneDump = ();

sub get_Modules()
{
    my $TOOL_DIR = dirname($0);
    my @SEARCH_DIRS = (
        # tool's directory
        abs_path($TOOL_DIR),
        # relative path to modules
        abs_path($TOOL_DIR)."/../share/japi-tracker",
        # install path
        'MODULES_INSTALL_PATH'
    );
    foreach my $DIR (@SEARCH_DIRS)
    {
        if(not $DIR=~/\A\//)
        { # relative path
            $DIR = abs_path($TOOL_DIR)."/".$DIR;
        }
        if(-d $DIR."/modules") {
            return $DIR."/modules";
        }
    }
    exitStatus("Module_Error", "can't find modules");
}

sub loadModule($)
{
    my $Name = $_[0];
    if(defined $LoadedModules{$Name}) {
        return;
    }
    my $Path = $MODULES_DIR."/Internals/$Name.pm";
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    require $Path;
    $LoadedModules{$Name} = 1;
}

sub readModule($$)
{
    my ($Module, $Name) = @_;
    my $Path = $MODULES_DIR."/Internals/$Module/".$Name;
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    return readFile($Path);
}

sub exitStatus($$)
{
    my ($Code, $Msg) = @_;
    printMsg("ERROR", $Msg);
    exit($ERROR_CODE{$Code});
}

sub printMsg($$)
{
    my ($Type, $Msg) = @_;
    if($Type!~/\AINFO/) {
        $Msg = $Type.": ".$Msg;
    }
    if($Type!~/_C\Z/) {
        $Msg .= "\n";
    }
    if($Type eq "ERROR") {
        print STDERR $Msg;
    }
    else {
        print $Msg;
    }
}

sub readProfile($)
{
    my $Content = $_[0];
    
    my %Res = ();
    
    if($Content=~/\A\s*\{\s*((.|\n)+?)\s*\}\s*\Z/)
    {
        my $Info = $1;
        my $Pos = 0;
        
        if($Info=~/\"(Versions|Supports)\"/)
        {
            my $Subj = $1;
            $Pos = 0;
            
            while($Info=~s/(\"$Subj\"\s*:\s*\[\s*)(\{\s*(.|\n)+?\s*\})\s*,?\s*/$1/)
            {
                my $SInfo = readProfile($2);
                
                if($Subj eq "Versions")
                {
                    if(my $Num = $SInfo->{"Number"})
                    {
                        $SInfo->{"Pos"} = $Pos++;
                        $Res{$Subj}{$Num} = $SInfo;
                    }
                    else {
                        printMsg("ERROR", "version number is missed in the profile");
                    }
                }
                elsif($Subj eq "Supports") {
                    $Res{$Subj}{$Pos++} = $SInfo;
                }
            }
        }
        
        # arrays
        while($Info=~s/\"(\w+)\"\s*:\s*\[\s*(.*?)\s*\]\s*(\,|\Z)//)
        {
            my ($K, $A) = ($1, $2);
            
            if($K eq "Versions"
            or $K eq "Supports") {
                next;
            }
            
            $Res{$K} = [];
            
            foreach my $E (split(/\s*\,\s*/, $A))
            {
                $E=~s/\A[\"\']//;
                $E=~s/[\"\']\Z//;
                
                push(@{$Res{$K}}, $E);
            }
        }
        
        # scalars
        while($Info=~s/\"(\w+)\"\s*:\s*(.+?)\s*\,?\s*$//m)
        {
            my ($K, $V) = ($1, $2);
            
            if($K eq "Versions"
            or $K eq "Supports") {
                next;
            }
            
            $V=~s/\A[\"\']//;
            $V=~s/[\"\']\Z//;
            
            $Res{$K} = $V;
        }
    }
    
    if(not $Res{"HideEmpty"}) {
        $Res{"HideEmpty"} = "On";
    }
    
    return \%Res;
}

sub skipVersion_T($)
{
    my $V = $_[0];
    
    if(defined $In::Opt{"TargetVersion"})
    {
        if($V ne $In::Opt{"TargetVersion"})
        {
            return 1;
        }
    }
    
    return 0;
}

sub skipVersion($)
{
    my $V = $_[0];
    
    if(defined $Profile->{"SkipVersions"})
    {
        my @Skip = @{$Profile->{"SkipVersions"}};
        
        foreach my $E (@Skip)
        {
            if($E=~/[\*\+\(\|\\]/)
            { # pattern
                if($V=~/\A$E\Z/) {
                    return 1;
                }
            }
            elsif($E eq $V) {
                return 1;
            }
        }
    }
    elsif(defined $Profile->{"SkipOdd"})
    {
        if($V=~/\A\d+\.(\d+)/)
        {
            if($1 % 2 == 1)
            {
                return 1;
            }
        }
    }
    
    return 0;
}

sub cleanUnused()
{
    printMsg("INFO", "Cleaning unused data");
    my @Versions = getVersionsList();
    
    my %SeqVer = ();
    my %PoinVer = ();
    
    foreach my $K (0 .. $#Versions)
    {
        my $V1 = $Versions[$K];
        my $V2 = undef;
        
        if($K<$#Versions) {
            $V2 = $Versions[$K+1];
        }
        
        $PoinVer{$V1} = 1;
        
        if(defined $V2) {
            $SeqVer{$V2}{$V1} = 1;
        }
    }
    
    foreach my $V (sort keys(%{$DB->{"APIDump"}}))
    {
        if(not defined $PoinVer{$V})
        {
            printMsg("INFO", "Unused API dump v$V");
            
            if(defined $In::Opt{"Confirm"}) {
                rmtree("api_dump/$TARGET_LIB/$V");
            }
        }
    }
    
    foreach my $O_V (sort keys(%{$DB->{"APIReport"}}))
    {
        foreach my $V (sort keys(%{$DB->{"APIReport"}{$O_V}}))
        {
            if(not defined $SeqVer{$O_V}{$V})
            {
                printMsg("INFO", "Unused API report from $O_V to $V");
                if(defined $In::Opt{"Confirm"})
                {
                    my $ArchiveDir = "archives_report/$TARGET_LIB/$O_V";
                    my $ReportDir = "compat_report/$TARGET_LIB/$O_V";
                    
                    rmtree($ArchiveDir."/".$V);
                    rmtree($ReportDir."/".$V);
                    
                    if(not listDir($ArchiveDir)) {
                        rmtree($ArchiveDir);
                    }
                    
                    if(not listDir($ReportDir)) {
                        rmtree($ReportDir);
                    }
                }
            }
        }
    }
    
    if(not defined $In::Opt{"Confirm"}) {
        printMsg("INFO", "Retry with -confirm option to remove files");
    }
}

sub buildData()
{
    my @Versions = getVersionsList();
    
    if($In::Opt{"TargetVersion"})
    {
        if(not grep {$_ eq $In::Opt{"TargetVersion"}} @Versions)
        {
            printMsg("ERROR", "unknown version number \'".$In::Opt{"TargetVersion"}."\'");
        }
    }
    
    my $ChangedAnnotations = undef;
    foreach my $V (reverse(@Versions))
    {
        if($Profile->{"Versions"}{$V}{"AddedAnnotations"})
        {
            $ChangedAnnotations = $V;
            last;
        }
    }
    
    if($ChangedAnnotations)
    {
        foreach my $V (reverse(@Versions))
        {
            if($V eq $ChangedAnnotations) {
                last;
            }
            else {
                $Profile->{"Versions"}{$V}{"WithoutAnnotations"} = 1;
            }
        }
    }
    
    foreach my $V (@Versions)
    {
        if(skipVersion_T($V)) {
            next;
        }
        if(my $Installed = $Profile->{"Versions"}{$V}{"Installed"})
        {
            if(not -d $Installed)
            {
                printMsg("ERROR", "$V is not installed");
            }
        }
    }
    
    if(checkTarget("date")
    or checkTarget("dates"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            detectDate($V);
        }
    }
    
    if(checkTarget("changelog"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            createChangelog($V, $V eq $Versions[$#Versions]);
        }
    }
    
    if(checkTarget("apidump"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            createAPIDump($V);
        }
    }
    
    if(checkTarget("compress"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            compressAPIDump($V);
            compressAPIReport_D($V);
            compressAPIReport($V);
        }
    }
    
    if($In::Opt{"Rebuild"} and not $In::Opt{"TargetElement"} and $In::Opt{"TargetVersion"})
    { # rebuild previous API dump
        my $PV = undef;
        
        foreach my $V (reverse(@Versions))
        {
            if($V eq $In::Opt{"TargetVersion"})
            {
                if(defined $PV)
                {
                    createAPIDump($PV);
                    last;
                }
            }
            $PV = $V;
        }
    }
    
    foreach my $P (0 .. $#Versions)
    {
        my $V = $Versions[$P];
        my $O_V = undef;
        if($P<$#Versions) {
            $O_V = $Versions[$P+1];
        }
        
        if(skipVersion_T($V)) {
            next;
        }
        
        if(defined $O_V)
        {
            if(checkTarget("apireport"))
            {
                createAPIReport($O_V, $V);
            }
            
            if(checkTarget("pkgdiff")
            or checkTarget("packagediff"))
            {
                if($V ne "current") {
                    createPkgdiff($O_V, $V);
                }
            }
        }
    }
    
    if(defined $Profile->{"Versions"}{"current"})
    { # save pull/update time of the code repository
        if(-d $Profile->{"Versions"}{"current"}{"Installed"})
        {
            if(my $UTime = getScmUpdateTime()) {
                $DB->{"ScmUpdateTime"} = $UTime;
            }
        }
    }
    
    if(my $SnapshotUpdateTime = getSnapshotUpdateTime()) {
        $DB->{"SnapshotUpdateTime"} = $SnapshotUpdateTime;
    }
    
    if(checkTarget("graph"))
    {
        printMsg("INFO", "Creating graph: API symbols/versions");
        
        my $Scatter = {};
        my $First = undef;
        
        foreach my $P (0 .. $#Versions)
        {
            my $V = $Versions[$P];
            my $O_V = undef;
            if($P<$#Versions) {
                $O_V = $Versions[$P+1];
            }
            
            if(defined $DB->{"APIReport"} and defined $DB->{"APIReport"}{$O_V}
            and defined $DB->{"APIReport"}{$O_V}{$V})
            {
                my $APIReport = $DB->{"APIReport"}{$O_V}{$V};
                
                my $Added = $APIReport->{"Added"};
                my $Removed = $APIReport->{"Removed"};
                
                my $AddedByArchives = $APIReport->{"ArchivesAddedSymbols"};
                my $RemovedByArchives = $APIReport->{"ArchivesRemovedSymbols"};
                
                $Scatter->{$V} = $Added - $Removed + $AddedByArchives - $RemovedByArchives;
                
                $First = $O_V;
            }
        }
        
        my $Total = 0;
        foreach my $Md5 (sort keys(%{$DB->{"APIDump"}{$First}}))
        {
            my $Dump = $DB->{"APIDump"}{$First}{$Md5};
            if(skipArchive($Dump->{"Archive"})) {
                next;
            }
            
            $Total += countSymbolsF($Dump, $First);
        }
        $Scatter->{$First} = 0;
        
        my @Order = reverse(@Versions);
        
        simpleGraph($Scatter, \@Order, $Total);
    }
}

sub simpleGraph($$$)
{
    my ($Scatter, $Order, $StartVal) = @_;
    
    my @Vs = ();
    foreach my $V (@{$Order})
    {
        if($V ne "current"
        and defined $Scatter->{$V})
        {
            push(@Vs, $V);
        }
    }
    
    my $Few = (defined $Profile->{"GraphFewXTics"} and $Profile->{"GraphFewXTics"} eq "On");
    
    if(not defined $Profile->{"GraphShortXTics"} or $Profile->{"GraphShortXTics"} eq "Off")
    {
        if(($Vs[0]=~/_/ and length($Vs[0])>=5) or length($Vs[0])>=7) {
            $Few = 1;
        }
        elsif(($Vs[$#Vs]=~/_/ and length($Vs[$#Vs])>=5) or length($Vs[$#Vs])>=7) {
            $Few = 1;
        }
    }
    
    my $P0 = 0;
    my $P1 = int($#Vs/4);
    my $P2 = int($#Vs/2);
    my $P3 = int(3*$#Vs/4);
    my $P4 = $#Vs;
    
    my $Tics = 5;
    if(defined $Profile->{"GraphXTics"}) {
        $Tics = $Profile->{"GraphXTics"};
    }
    
    if($Few) {
        $Tics = 3;
    }
    
    my $MinVer = $Vs[0];
    my $MaxVer = $Vs[$#Vs];
    
    my $MinRange = undef;
    my $MaxRange = undef;
    
    my $Content = "";
    my $Val_Pre = $StartVal;
    
    foreach (0 .. $#Vs)
    {
        my $V = $Vs[$_];
        
        my $Val = $Val_Pre + $Scatter->{$V};
        
        if(not defined $MinRange) {
            $MinRange = $Val;
        }
        
        if(not defined $MaxRange) {
            $MaxRange = $Val;
        }
        
        if($Val<$MinRange) {
            $MinRange = $Val;
        }
        elsif($Val>$MaxRange) {
            $MaxRange = $Val;
        }
        
        my $V_S = $V;
        
        if(defined $Profile->{"GraphShortXTics"} and $Profile->{"GraphShortXTics"} eq "On")
        {
            if($V=~tr!\.!!>=2) {
                $V_S = getMajor($V);
            }
        }
        
        $V_S=~s/\-(alpha|beta|rc|a|b)[\d\.\-]*\Z//g;
        
        if($V_S eq "SNAPSHOT") {
            $V_S = "snapshot";
        }
        
        $Content .= $_."  ".$Val;
        
        if($_==$P0 or $_==$P4
        or $_==$P2)
        {
            $Content .= "  ".$V_S;
        }
        elsif($Tics==5 and ($_==$P1
        or $_==$P3))
        {
            $Content .= "  ".$V_S;
        }
        $Content .= "\n";
        
        $Val_Pre = $Val;
    }
    
    my $Delta = $MaxRange - $MinRange;
    
    if($Delta<20)
    {
        if($MinRange>5) {
            $MinRange -= 5;
        }
        elsif($MinRange>0) {
            $MinRange -= 1;
        }
        $MaxRange += 5;
    }
    else
    {
        if($MinRange>int($Delta/20)) {
            $MinRange -= int($Delta/20);
        }
        $MaxRange += int($Delta/20);
    }
    
    my $LegendDefault = undef;
    
    $Val_Pre = $StartVal;
    my %Top = ();
    
    foreach my $X (0 .. $#Vs)
    {
        my $V = $Vs[$X];
        my $Val = $Val_Pre + $Scatter->{$V};
        
        if(grep {$X eq $_} ($P0, $P1, $P2, $P3, $P4)) {
            $Top{$X} = ($Val - $MinRange)/($MaxRange - $MinRange);
        }
        $Val_Pre = $Val;
    }
    
    if($Top{$P0}<0.7 and $Top{$P1}<0.7 and $Top{$P2}<0.7) {
        $LegendDefault = "LeftTop";
    }
    elsif($Top{$P2}<0.7 and $Top{$P3}<0.7 and $Top{$P4}<0.7) {
        $LegendDefault = "RightTop";
    }
    elsif($Top{$P2}>=0.35 and $Top{$P3}>=0.35 and $Top{$P4}>=0.35) {
        $LegendDefault = "RightBottom";
    }
    elsif($Top{$P0}>=0.35 and $Top{$P1}>=0.35 and $Top{$P2}>=0.35) {
        $LegendDefault = "LeftBottom";
    }
    elsif($Top{$P1}<0.7 and $Top{$P2}<0.7 and $Top{$P3}<0.7) {
        $LegendDefault = "CenterTop";
    }
    elsif($Top{$P1}>=0.35 and $Top{$P2}>=0.35 and $Top{$P3}>=0.35) {
        $LegendDefault = "CenterBottom";
    }
    elsif($Top{$P0}<0.72 and $Top{$P1}<0.72) {
        $LegendDefault = "LeftTop";
    }
    elsif($Top{$P3}<0.72 and $Top{$P4}<0.72) {
        $LegendDefault = "RightTop";
    }
    elsif($Top{$P3}>=0.33 and $Top{$P4}>=0.33) {
        $LegendDefault = "RightBottom";
    }
    elsif($Top{$P0}>=0.35 and $Top{$P1}>=0.35) {
        $LegendDefault = "LeftBottom";
    }
    elsif($Top{$P2}<0.72) {
        $LegendDefault = "CenterTop";
    }
    elsif($Top{$P2}>=0.33) {
        $LegendDefault = "CenterBottom";
    }
    else {
        $LegendDefault = "LeftTop";
    }
    
    my $Data = $TMP_DIR."/graph.data";
    
    writeFile($Data, $Content);
    
    my $GraphTitle = ""; # Timeline of API changes
    
    my $GraphPath = "graph/$TARGET_LIB/graph.svg";
    mkpath(getDirname($GraphPath));
    
    my $Title = showTitle();
    $Title=~s/\'/''/g;
    
    my $Cmd = "gnuplot -e \"set title \'$GraphTitle\';";
    
    my ($Left, $Center, $Right, $Top, $Bottom) = (0.54, 0.8, 0.95, 0.9, 0.3);
    
    if($MaxRange>=10000) {
        $Left = 0.61;
    }
    elsif($MaxRange>=1000) {
        $Left = 0.58;
    }
    elsif($MaxRange>=100) {
        $Left = 0.55;
    }
    
    if(not $Profile->{"GraphLegendPos"}) {
        $Profile->{"GraphLegendPos"} = $LegendDefault;
    }
    
    if($Profile->{"GraphLegendPos"} eq "RightTop") {
        $Cmd .= "set key at graph $Right,$Top;";
    }
    elsif($Profile->{"GraphLegendPos"} eq "CenterTop") {
        $Cmd .= "set key at graph $Center,$Top;";
    }
    elsif($Profile->{"GraphLegendPos"} eq "RightBottom") {
        $Cmd .= "set key at graph $Right,$Bottom;";
    }
    elsif($Profile->{"GraphLegendPos"} eq "CenterBottom") {
        $Cmd .= "set key at graph $Center,$Bottom;";
    }
    elsif($Profile->{"GraphLegendPos"} eq "LeftBottom") {
        $Cmd .= "set key at graph $Left,$Bottom;";
    }
    elsif($Profile->{"GraphLegendPos"} eq "LeftTop") {
        $Cmd .= "set key at graph $Left,$Top;";
    }
    
    $Cmd .= "set key font 'FreeSans, 11';";
    $Cmd .= "set xrange [0:".$#Vs."];";
    $Cmd .= "set yrange [$MinRange:$MaxRange];";
    $Cmd .= "set terminal svg size 325,250;";
    $Cmd .= "set output \'$GraphPath\';";
    $Cmd .= "set xtics font 'FreeSans, 13';";
    $Cmd .= "set ytics font 'FreeSans, 13';";
    $Cmd .= "set style line 1 linecolor rgbcolor 'red' linewidth 2;";
    $Cmd .= "set style increment user;";
    $Cmd .= "plot \'$Data\' using 2:xticlabels(3) title 'API\nSymbols' with lines\"";
    
    system($Cmd);
    unlink($Data);
}

sub findArchives($)
{
    my $Dir = $_[0];
    
    my @Files = findFiles($Dir, "f", ".*\\.jar");
    my @Modules = findFiles($Dir, "f", ".*\\.jmod");
    
    push(@Files, @Modules);
    
    return @Files;
}

sub skipArchive($)
{
    if(matchFile($_[0], "SkipArchives")) {
        return 1;
    }
    
    if(defined $Profile->{"CheckArchives"})
    {
        if(not matchFile($_[0], "CheckArchives")) {
            return 1;
        }
    }
    
    return 0;
}

sub matchFile($$)
{
    my ($Path, $Tag) = @_;
    
    if(defined $Profile->{$Tag})
    {
        my $Name = getFilename($Path);
        my @Skip = @{$Profile->{$Tag}};
        
        foreach my $L (@Skip)
        {
            if($L eq $Name)
            { # exact match
                return 1;
            }
            elsif($L=~/\/\Z/)
            { # directory
                if($Path=~/\Q$L\E/) {
                    return 1;
                }
            }
            else
            { # file
                if($L=~/[\*\+\(\|\\]/)
                { # pattern
                    if($Name=~/\A$L\Z/) {
                        return 1;
                    }
                }
                elsif($Tag eq "SkipArchives"
                or $Tag eq "CheckArchives")
                { # short name
                    if($L eq getArchiveName($Name, "Short")) {
                        return 1;
                    }
                }
            }
        }
    }
    
    return 0;
}

sub updateRequired($)
{
    my $V = $_[0];
    
    if($V eq "current")
    {
        if($DB->{"ScmUpdateTime"})
        {
            if(my $UTime = getScmUpdateTime())
            {
                if($DB->{"ScmUpdateTime"} ne $UTime)
                {
                    return 1;
                }
            }
        }
    }
    else
    {
        if(isSnapshot($V, $Profile))
        {
            if(defined $DB->{"SnapshotUpdateTime"})
            {
                if(my $UTime = getSnapshotUpdateTime())
                {
                    if($DB->{"SnapshotUpdateTime"} ne $UTime)
                    {
                        return 1;
                    }
                }
            }
            else
            {
                return 1;
            }
        }
    }
    
    return 0;
}

sub getSnapshotUpdateTime()
{
    if(my $SnapshotVer = $Profile->{"SnapshotVer"})
    {
        if(defined $Profile->{"Versions"}{$SnapshotVer}) {
            return getTimeF($Profile->{"Versions"}{$SnapshotVer}{"Source"});
        }
    }
    
    return undef;
}

sub createChangelog($$)
{
    my $V = $_[0];
    my $First = $_[1];
    
    if(defined $Profile->{"Versions"}{$V}{"Changelog"})
    {
        if($Profile->{"Versions"}{$V}{"Changelog"} eq "Off"
        or index($Profile->{"Versions"}{$V}{"Changelog"}, "://")!=-1)
        {
            return 0;
        }
    }
    
    if(not $In::Opt{"Rebuild"})
    {
        if(defined $DB->{"Changelog"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    printMsg("INFO", "Creating changelog for $V");
    
    my $Source = $Profile->{"Versions"}{$V}{"Source"};
    my $ChangelogPath = undef;
    
    if(not -e $Source)
    {
        printMsg("ERROR", "Can't access \'$Source\'");
        return 0;
    }
    
    my $TmpDir = $TMP_DIR."/log/";
    mkpath($TmpDir);
    
    if($V eq "current")
    {
        $ChangelogPath = "$TmpDir/log";
        chdir($Source);
        
        my $Cmd_L = undef;
        if(defined $Profile->{"Git"})
        {
            $Cmd_L = "git log -100 --date=iso >$ChangelogPath";
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Cmd_L = "svn log -l100 >$ChangelogPath";
        }
        else
        {
            printMsg("ERROR", "Unknown type of source code repository");
            return 0;
        }
        qx/$Cmd_L/; # execute
        appendFile($ChangelogPath, "\n...");
        chdir($ORIG_DIR);
    }
    else
    {
        if(my $Cmd_E = extractPackage($Source, $TmpDir))
        {
            qx/$Cmd_E/; # execute
            if($?)
            {
                printMsg("ERROR", "Failed to extract package \'".getFilename($Source)."\'");
                return 0;
            }
        }
        else
        {
            printMsg("ERROR", "Unknown package format \'".getFilename($Source)."\'");
            return 0;
        }
        
        my @Files = listDir($TmpDir);
        
        if($#Files==0) {
            $TmpDir .= "/".$Files[0];
        }
        
        if(defined $Profile->{"Versions"}{$V}{"Changelog"})
        {
            my $Target = $Profile->{"Versions"}{$V}{"Changelog"};
            
            if($Target eq "On")
            {
                my $Found = findChangelog($TmpDir);
                
                if($Found and $Found ne "None") {
                    $ChangelogPath = $TmpDir."/".$Found;
                }
            }
            else
            { # name of the changelog
                if(-f $TmpDir."/".$Target
                and -s $TmpDir."/".$Target)
                {
                    $ChangelogPath = $TmpDir."/".$Target;
                }
            }
        }
    }
    
    my $Dir = "changelog/$TARGET_LIB/$V";
    
    if($ChangelogPath)
    {
        my $Html = toHtml($V, $ChangelogPath, $First);
        
        writeFile($Dir."/log.html", $Html);
        
        $DB->{"Changelog"}{$V} = $Dir."/log.html";
    }
    else
    {
        rmtree($Dir);
        $DB->{"Changelog"}{$V} = "Off";
    }
    
    rmtree($TmpDir);
}

sub toHtml($$$)
{
    my ($V, $Path, $First) = @_;
    my $Content = readFile($Path);
    
    my $LIM = 500000;
    
    if(not $First and $V ne "current") {
        $LIM /= 20;
    }
    
    if(length($Content)>$LIM)
    {
        $Content = substr($Content, 0, $LIM);
        $Content .= "\n...";
    }
    
    $Content = htmlSpecChars($Content, 1);
    
    my $Title = showTitle()." ".$V.": changelog";
    my $Keywords = showTitle().", $V, changes, changelog";
    my $Desc = "Log of changes in the package";
    
    $Content = "\n<div class='changelog'>\n<pre class='wrap'>$Content</pre></div>\n";
    
    if($V eq "current")
    {
        my $Note = "source repository";
        if(defined $Profile->{"Git"})
        {
            $Note = "Git";
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Note = "Svn";
        }
        
        $Content = "<h1>Changelog from $Note</h1><br/><br/>".$Content;
    }
    else {
        $Content = "<h1>Changelog for <span class='version'>$V</span> version</h1><br/><br/>".$Content;
    }
    $Content = getHead("changelog").$Content;
    
    $Content = composeHTML_Head("changelog", $Title, $Keywords, $Desc, "changelog.css")."\n<body>\n$Content\n</body>\n</html>\n";
    
    return $Content;
}

sub htmlSpecChars(@)
{
    my $S = shift(@_);
    
    my $Sp = 0;
    
    if(@_) {
        $Sp = shift(@_);
    }
    
    $S=~s/\&([^#])/&amp;$1/g;
    $S=~s/</&lt;/g;
    $S=~s/>/&gt;/g;
    
    if(not $Sp)
    {
        $S=~s/([^ ]) ([^ ])/$1\@SP\@$2/g;
        $S=~s/([^ ]) ([^ ])/$1\@SP\@$2/g;
        $S=~s/ /&nbsp;/g;
        $S=~s/\@SP\@/ /g;
        $S=~s/\n/\n<br\/>/g;
    }
    
    return $S;
}

sub findChangelog($)
{
    my $Dir = $_[0];
    
    foreach my $Name ("NEWS", "CHANGES", "CHANGES.txt", "RELEASE_NOTES", "ChangeLog", "Changelog",
    "RELEASE_NOTES.md", "RELEASE_NOTES.markdown")
    {
        if(-f $Dir."/".$Name
        and -s $Dir."/".$Name)
        {
            return $Name;
        }
    }
    
    return "None";
}

sub getScmUpdateTime()
{
    if(my $Source = $Profile->{"Versions"}{"current"}{"Source"})
    {
        if(not -d $Source) {
            return undef;
        }
        
        my $Time = undef;
        my $Head = undef;
        
        if(defined $Profile->{"Git"})
        {
            $Head = "$Source/.git/refs/heads/master";
            
            if(not -f $Head)
            { # is not updated yet
                $Head = "$Source/.git/FETCH_HEAD";
            }
            
            if(not -f $Head)
            {
                $Head = undef;
            }
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Head = "$Source/.svn/wc.db";
            
            if(not -f $Head)
            {
                $Head = undef;
            }
        }
        
        if($Head) {
            $Time = getTimeF($Head);
        }
        
        if($Time) {
            return $Time;
        }
    }
    
    return undef;
}

sub getTimeF($)
{
    my $Path = $_[0];
    
    my $Time = `stat -c \%Y \"$Path\"`;
    chomp($Time);
    
    return $Time;
}

sub checkTarget($)
{
    my $Elem = $_[0];
    
    if(defined $In::Opt{"TargetElement"})
    {
        if($Elem ne $In::Opt{"TargetElement"})
        {
            return 0;
        }
    }
    
    return 1;
}

sub detectDate($)
{
    my $V = $_[0];
    
    if(not $In::Opt{"Rebuild"})
    {
        if(defined $DB->{"Date"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    printMsg("INFO", "Detecting date of $V");
    
    my $Source = $Profile->{"Versions"}{$V}{"Source"};
    my $Date = undef;
    
    if($V eq "current")
    {
        if(defined $Profile->{"Git"})
        {
            chdir($Source);
            my $Log = `git log -1 --date=iso`;
            chdir($ORIG_DIR);
            
            if($Log=~/ (\d+\-\d+\-\d+ \d+:\d+:\d+) /)
            {
                $Date = $1;
            }
        }
        elsif(defined $Profile->{"Svn"})
        {
            chdir($Source);
            my $Log = `svn log -l1`;
            chdir($ORIG_DIR);
            
            if($Log=~/ (\d+\-\d+\-\d+ \d+:\d+:\d+) /)
            {
                $Date = $1;
            }
        }
        else
        {
            printMsg("ERROR", "Unknown type of source code repository");
            return 0;
        }
    }
    else
    {
        my @Files = listPackage($Source);
        my %Dates = ();
        
        my $Zip = ($Source=~/\.(zip|jar|aar)\Z/i);
        
        foreach my $Line (@Files)
        {
            if($Line!~/\Ad/ # skip directories
            and $Line=~/ (\d+)\-(\d+)\-(\d+) (\d+:\d+) /)
            {
                my $Date = undef;
                my $Time = $4;
                
                if($Zip) {
                    $Date = $3."-".$1."-".$2;
                }
                else {
                    $Date = $1."-".$2."-".$3;
                }
                
                $Dates{$Date." ".$Time} = 1;
            }
        }
        
        if(my @Sorted = sort {$b cmp $a} keys(%Dates)) {
            $Date = $Sorted[0];
        }
    }
    
    if($Date) {
        $DB->{"Date"}{$V} = $Date;
    }
}

sub listPackage($)
{
    my $Path = $_[0];
    
    my $Cmd = "";
    
    if($Path=~/\.(tar\.\w+|tgz|tbz2)\Z/i) {
        $Cmd = "tar -tvf \"$Path\"";
    }
    elsif($Path=~/\.(zip|jar|aar|jmod)\Z/i) {
        $Cmd = "unzip -l $Path";
    }
    
    if($Cmd)
    {
        my @Res = split(/\n/, `$Cmd 2>/dev/null`);
        return @Res;
    }
    
    return ();
}

sub readDump($)
{
    my $Path = abs_path($_[0]);
    
    if($Path!~/\.\Q$COMPRESS\E\Z/) {
        return readFile($Path);
    }
    
    my $Cmd_E = "tar -xOf \"$Path\"";
    my $Content = qx/$Cmd_E/;
    return $Content;
}

sub compressAPIDump($)
{
    my $V = $_[0];
    
    if(not defined $DB->{"APIDump"}{$V}) {
        return;
    }
    
    foreach my $Md5 (keys(%{$DB->{"APIDump"}{$V}}))
    {
        my $DumpPath = $DB->{"APIDump"}{$V}{$Md5}{"Path"};
        
        if($DumpPath=~/\.\Q$COMPRESS\E\Z/) {
            next;
        }
        
        printMsg("INFO", "Compressing $DumpPath");
        my $Dir = getDirname($DumpPath);
        my $Name = getFilename($DumpPath);
        my @Cmd_C = ("tar", "-C", $Dir, "-czf", $DumpPath.".".$COMPRESS, $Name);
        system(@Cmd_C);
        
        if($?) {
            exitStatus("Error", "Can't compress API dump");
        }
        else {
            unlink($DumpPath);
        }
    }
}

sub compressAPIReport_D($)
{
    my $V1 = $_[0];
    
    foreach my $V2 (keys(%{$DB->{"APIReport_D"}{$V1}}))
    {
        foreach my $Md5 (keys(%{$DB->{"APIReport_D"}{$V1}{$V2}}))
        {
            my $ReportPath = $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}{"Path"};
            
            if($ReportPath!~/\.\Q$COMPRESS\E\Z/ and -e $ReportPath)
            {
                printMsg("INFO", "Compressing $ReportPath");
                my $Dir = getDirname($ReportPath);
                my $Name = getFilename($ReportPath);
                my @Cmd_C = ("tar", "-C", $Dir, "-czf", $ReportPath.".".$COMPRESS, $Name);
                system(@Cmd_C);
                
                if($?) {
                    exitStatus("Error", "Can't compress API report");
                }
                else
                {
                    unlink($ReportPath);
                    
                    $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}{"Path"} = $ReportPath.".".$COMPRESS;
                    $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}{"WWWPath"} = $ReportPath;
                }
            }
            
            my $SrcReportPath = $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}{"Source_ReportPath"};
            
            if($SrcReportPath!~/\.\Q$COMPRESS\E\Z/ and -e $SrcReportPath)
            {
                printMsg("INFO", "Compressing $SrcReportPath");
                my $Dir = getDirname($SrcReportPath);
                my $Name = getFilename($SrcReportPath);
                my @Cmd_C = ("tar", "-C", $Dir, "-czf", $SrcReportPath.".".$COMPRESS, $Name);
                system(@Cmd_C);
                
                if($?) {
                    exitStatus("Error", "Can't compress API report");
                }
                else
                {
                    unlink($SrcReportPath);
                    
                    $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}{"Source_ReportPath"} = $SrcReportPath.".".$COMPRESS;
                    $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}{"WWWSource_ReportPath"} = $SrcReportPath;
                }
            }
        }
    }
}

sub compressAPIReport($)
{
    my $V1 = $_[0];
    
    foreach my $V2 (keys(%{$DB->{"APIReport"}{$V1}}))
    {
        my $ReportPath = $DB->{"APIReport"}{$V1}{$V2}{"Path"};
        
        if($ReportPath=~/\.\Q$COMPRESS\E\Z/ or not -e $ReportPath) {
            next;
        }
        
        printMsg("INFO", "Compressing $ReportPath");
        my $Dir = getDirname($ReportPath);
        my $Name = getFilename($ReportPath);
        my @Cmd_C = ("tar", "-C", $Dir, "-czf", $ReportPath.".".$COMPRESS, $Name);
        system(@Cmd_C);
        
        if($?) {
            exitStatus("Error", "Can't compress API archives report");
        }
        else
        {
            unlink($ReportPath);
            
            $DB->{"APIReport"}{$V1}{$V2}{"Path"} = $ReportPath.".".$COMPRESS;
            $DB->{"APIReport"}{$V1}{$V2}{"WWWPath"} = $ReportPath;
        }
    }
}

sub createAPIDump($)
{
    my $V = $_[0];
    
    if(not $In::Opt{"Rebuild"})
    {
        if(defined $DB->{"APIDump"}{$V})
        {
            if(not updateRequired($V)) {
                return 1;
            }
        }
    }
    
    printMsg("INFO", "Creating API dump for $V");
    
    my $Installed = $Profile->{"Versions"}{$V}{"Installed"};
    
    if(not -d $Installed) {
        return 0;
    }
    
    my @Archives = findArchives($Installed);
    
    my $Dir = "api_dump/$TARGET_LIB/$V";
    
    if(-d $Dir) {
        rmtree($Dir);
    }
    
    if(not @Archives)
    {
        printMsg("ERROR", "can't find archives");
        return 0;
    }
    
    delete($DB->{"APIDump"}{$V});
    
    foreach my $Ar (sort {lc($a) cmp lc($b)} @Archives)
    {
        my $RPath = $Ar;
        $RPath=~s/\A\Q$Installed\E\/*//;
        
        if(skipArchive($RPath)) {
            next;
        }
        
        printMsg("INFO", "Creating API dump for $RPath");
        
        my $Md5 = getMd5($RPath);
        
        my $APIDir = $Dir."/".$Md5;
        my $APIDump = $APIDir."/API.dump";
        if(not $Profile->{"NoCompress"}) {
            $APIDump .= ".".$COMPRESS;
        }
        my $Name = getFilename($Ar);
        
        my $Module = getArchiveName(getFilename($Ar), "Short");
        if(not $Module) {
            $Module = getFilename($Ar);
        }
        
        my $Cmd = $JAPICC." -l \"$Module\" -dump \"".$Ar."\" -dump-path \"".$APIDump."\" -vnum \"$V\"";
        if(my $DumpOpts = getDump_Options()) {
            $Cmd .= " ".$DumpOpts;
        }
        
        if(not $Profile->{"PrivateAPI"})
        { # set "PrivateAPI":1 in the profile to check all symbols
            
        }
        
        if($In::Opt{"Debug"}) {
            printMsg("DEBUG", "executing $Cmd");
        }
        
        my $Log = `$Cmd`; # execute
        
        if(-f $APIDump)
        {
            $DB->{"APIDump"}{$V}{$Md5}{"Path"} = $APIDump;
            $DB->{"APIDump"}{$V}{$Md5}{"Archive"} = $RPath;
            
            # my $API = eval(readDump($APIDump));
            # $DB->{"APIDump"}{$V}{$Md5}{"Lang"} = $API->{"Language"};
            
            my $TotalSymbols = countSymbols($DB->{"APIDump"}{$V}{$Md5});
            $DB->{"APIDump"}{$V}{$Md5}{"TotalSymbols"} = $TotalSymbols;
            
            my @Meta = ();
            
            push(@Meta, "\"Archive\": \"".$RPath."\"");
            # push(@Meta, "\"Lang\": \"".$API->{"Language"}."\"");
            push(@Meta, "\"TotalSymbols\": \"".$TotalSymbols."\"");
            push(@Meta, "\"PublicAPI\": \"1\"");
            
            writeFile($Dir."/".$Md5."/meta.json", "{\n  ".join(",\n  ", @Meta)."\n}");
        }
        else
        {
            printMsg("ERROR", "can't create API dump");
            rmtree($APIDir);
        }
    }
    
    $DoneDump{$V} = 1;
    
    return 1;
}

sub countSymbolsF($$)
{
    my ($Dump, $V) = @_;
    
    if(defined $Dump->{"TotalSymbolsFiltered"} and $Dump->{"TotalSymbolsFiltered"})
    {
        if(not defined $In::Opt{"DisableCache"}) {
            return $Dump->{"TotalSymbolsFiltered"};
        }
    }
    
    my $AccOpts = getJAPICC_Options($V);
    
    if(defined $In::Opt{"DisableCache"} or ($AccOpts=~/list|skip|keep|check/
    and not $Profile->{"Versions"}{$V}{"WithoutAnnotations"}))
    {
        my $Path = $Dump->{"Path"};
        printMsg("INFO", "Counting symbols in the API dump for \'".getFilename($Dump->{"Archive"})."\'");
        
        my $Cmd_C = "$JAPICC -count-methods \"$Path\" $AccOpts";
        
        if($In::Opt{"Debug"}) {
            printMsg("DEBUG", "executing $Cmd_C");
        }
        
        my $Count = qx/$Cmd_C/;
        chomp($Count);
        
        return ($Dump->{"TotalSymbolsFiltered"} = $Count);
    }
    
    return ($Dump->{"TotalSymbolsFiltered"} = $Dump->{"TotalSymbols"});
}

sub countSymbolsM($)
{
    my $Dump = $_[0];
    
    my $Total = 0;
    foreach my $M (keys(%{$Dump->{"MethodInfo"}}))
    {
        my $Access = $Dump->{"MethodInfo"}{$M}{"Access"};
        my $ClassId = $Dump->{"MethodInfo"}{$M}{"Class"};
        my $Class = $Dump->{"TypeInfo"}{$ClassId};
        my $ClassAccess = $Class->{"Access"};
        
        if($Access ne "private"
        and $Access ne "package-private"
        and $ClassAccess ne "private"
        and $ClassAccess ne "package-private") {
            $Total+=1;
        }
    }
    
    return "$Total";
}

sub countSymbols($)
{
    my $Dump = $_[0];
    my $Path = $Dump->{"Path"};
    
    printMsg("INFO", "Counting methods in the API dump for \'".getFilename($Dump->{"Archive"})."\'");
    
    my $Cmd_C = "$JAPICC -count-methods \"$Path\"";
    
    if($In::Opt{"Debug"}) {
        printMsg("DEBUG", "executing $Cmd_C");
    }
    
    my $Total = qx/$Cmd_C/;
    chomp($Total);
    
    return $Total;
}

sub getArchiveName($$)
{
    my ($Ar, $T) = @_;
    
    my $Name = getFilename($Ar);
    my $Dir = getDirname($Ar);
    
    $Name=~s/\.(jar|aar|jmod)\Z//g;
    
    if(my $Suffix = $Profile->{"ArchiveSuffix"}) {
        $Name=~s/\Q$Suffix\E\Z//g;
    }
    
    if($T=~/Shortest/)
    { # httpcore5-5.0-alpha1.jar
        $Name=~s/\A([a-z]{3,})\d+(\-)/$1$2/ig;
    }
    
    if($T=~/Short/)
    {
        if(not $Name=~s/\A(.+?)[\-\_][v\d\.\-\_]+(|[\-\_\.](final|release|snapshot|RC\d*|beta\d*|alpha\-?\d*))\Z/$1/ig)
        { # NAME-X.Y.Z-SUBJ.jar
            $Name=~s/\A(.+?)\-[\d\.]+\-(.+?)/$1-$2/ig;
        }
    }
    
    if($T=~/Dir/)
    {
        if($Dir) {
            $Name = $Dir."/".$Name;
        }
    }
    
    return $Name;
}

sub createAPIReport($$)
{
    my ($V1, $V2) = @_;
    
    if(not $In::Opt{"Rebuild"})
    {
        if(defined $DB->{"APIReport"}{$V1}{$V2})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    printMsg("INFO", "Creating archives API report between $V1 and $V2");
    
    my $Cols = 6;
    
    if($Profile->{"CompatRate"} eq "Off") {
        $Cols-=2;
    }
    
    if($Profile->{"ShowTotalProblems"} ne "On") {
        $Cols-=2;
    }
    
    if($V2 eq "current")
    { # NOTE: additional check of consistency
        if(defined $DB->{"APIDump"}{$V2})
        {
            my $IPath = $Profile->{"Versions"}{$V2}{"Installed"};
            foreach my $Md (sort keys(%{$DB->{"APIDump"}{$V2}}))
            {
                if(not -e $IPath."/".$DB->{"APIDump"}{$V2}{$Md}{"Archive"})
                {
                    print STDERR "WARNING: It's necessary to regenerate API dump for $V2\n";
                    delete($DB->{"APIDump"}{$V2});
                    last;
                }
            }
            
            # TODO: check if all JARs are dumped
        }
    }
    
    if(defined $In::Opt{"RegenDump"}
    and $Profile->{"RegenDump"} ne "Off"
    and not defined $DoneDump{$V1})
    {
        print "INFO: Regenerating API dump for $V1\n";
        delete($DB->{"APIDump"}{$V1});
    }
    
    if(defined $In::Opt{"RegenDump"}
    and $Profile->{"RegenDump"} ne "Off"
    and not defined $DoneDump{$V2})
    {
        print "INFO: Regenerating API dump for $V2\n";
        delete($DB->{"APIDump"}{$V2});
    }
    
    if(not defined $DB->{"APIDump"}{$V1})
    {
        if(not createAPIDump($V1))
        {
            printMsg("ERROR", "Failed to generate API dump for $V1");
            return 0;
        }
    }
    
    if(not defined $DB->{"APIDump"}{$V2})
    {
        if(not createAPIDump($V2))
        {
            printMsg("ERROR", "Failed to generate API dump for $V2");
            return 0;
        }
    }
    
    my $D1 = $DB->{"APIDump"}{$V1};
    my $D2 = $DB->{"APIDump"}{$V2};
    
    if(not $D1 or not $D2) {
        return 0;
    }
    
    my (@Archives1, @Archives2) = ();
    my %ArchiveDump = ();
    
    foreach my $Md5 (sort keys(%{$D1}))
    {
        my $Ar = $D1->{$Md5}{"Archive"};
        if(skipArchive($Ar)) {
            next;
        }
        push(@Archives1, $Ar);
        
        $ArchiveDump{1}{$Ar} = $D1->{$Md5};
    }
    
    foreach my $Md5 (sort keys(%{$D2}))
    {
        my $Ar = $D2->{$Md5}{"Archive"};
        if(skipArchive($Ar)) {
            next;
        }
        push(@Archives2, $Ar);
        
        $ArchiveDump{2}{$Ar} = $D2->{$Md5};
    }
    
    delete($DB->{"APIReport"}{$V1}{$V2});
    
    @Archives1 = sort {lc($a) cmp lc($b)} @Archives1;
    @Archives2 = sort {lc($a) cmp lc($b)} @Archives2;
    
    my %ShortName2 = ();
    my %ShortNameDir2 = ();
    my %ShortestName2 = ();
    
    foreach my $Archive2 (@Archives2)
    {
        if(skipArchive($Archive2)) {
            next;
        }
        if(my $Short = getArchiveName($Archive2, "Short")) {
            $ShortName2{$Short}{$Archive2} = 1;
        }
        if(my $Shortest = getArchiveName($Archive2, "Shortest")) {
            $ShortestName2{$Shortest}{$Archive2} = 1;
        }
    }
    
    foreach my $Archive2 (@Archives2)
    {
        if(skipArchive($Archive2)) {
            next;
        }
        if(my $Short = getArchiveName($Archive2, "Short + Dir")) {
            $ShortNameDir2{$Short}{$Archive2} = 1;
        }
    }
    
    my (%Added, %Removed, %Mapped, %Mapped_R, %RenamedArchive) = ();
    
    # Match archives
    foreach my $Archive1 (@Archives1)
    {
        my $Archive2 = undef;
        
        # Try to match by name
        if(not $Archive2)
        {
            if(grep {$_ eq $Archive1} @Archives2) {
                $Archive2 = $Archive1;
            }
        }
        
        # Try to match by short name + dir
        if(not $Archive2)
        {
            my $Short = getArchiveName($Archive1, "Short + Dir");
            
            if(defined $ShortNameDir2{$Short})
            {
                my @Pair = keys(%{$ShortNameDir2{$Short}});
                
                if($#Pair==0)
                {
                    $Archive2 = $Pair[0];
                    delete($ShortNameDir2{$Short});
                }
            }
        }
        
        # Try to match by short name
        if(not $Archive2)
        {
            my $Short = getArchiveName($Archive1, "Short");
            
            if(defined $ShortName2{$Short})
            {
                my @Pair = keys(%{$ShortName2{$Short}});
                
                if($#Pair==0)
                {
                    $Archive2 = $Pair[0];
                    delete($ShortName2{$Short});
                }
            }
        }
        
        # Try to match by shortest name
        if(not $Archive2)
        {
            my $Short = getArchiveName($Archive1, "Shortest");
            
            if(defined $ShortestName2{$Short})
            {
                my @Pair = keys(%{$ShortestName2{$Short}});
                
                if($#Pair==0)
                {
                    $Archive2 = $Pair[0];
                    delete($ShortestName2{$Short});
                }
            }
        }
        
        if($Archive2
        and not defined $Mapped_R{$Archive2})
        {
            $Mapped{$Archive1} = $Archive2;
            $Mapped_R{$Archive2} = $Archive1;
        }
        else {
            $Removed{$Archive1} = 1;
        }
    }
    
    foreach my $Archive2 (@Archives2)
    {
        if(not defined $Mapped_R{$Archive2}) {
            $Added{$Archive2} = 1;
        }
    }
    
    if(not keys(%Mapped))
    {
        if($#Archives1==0 and $#Archives2==0)
        {
            $Mapped{$Archives1[0]} = $Archives2[0];
            $RenamedArchive{$Archives1[0]} = $Archives2[0];
            
            delete($Removed{$Archives1[0]});
            delete($Added{$Archives2[0]});
        }
    }
    
    if($Profile->{"Versions"}{$V2}{"AddedAnnotations"})
    {
        foreach my $Archive1 (keys(%Mapped))
        {
            my $Archive2 = $Mapped{$Archive1};
            if(countSymbolsF($ArchiveDump{1}{$Archive1}, $V1)
            and not countSymbolsF($ArchiveDump{2}{$Archive2}, $V2))
            {
                delete($Mapped{$Archive1});
                $Removed{$Archive1} = 1;
            }
        }
    }
    
    my @Archives = sort keys(%Mapped);
    
    if(not $ArchivesReport)
    {
        if($In::Opt{"Rebuild"})
        {
            # Remove old reports
            my $CDir = "compat_report/$TARGET_LIB/$V1/$V2";
            
            if(-d $CDir) {
                rmtree($CDir);
            }
        }
        
        foreach my $Archive1 (@Archives)
        {
            if(skipArchive($Archive1)) {
                next;
            }
            compareAPIs($V1, $V2, $Archive1, $Mapped{$Archive1});
        }
    }
    
    my $Dir = "archives_report/$TARGET_LIB/$V1/$V2";
    
    if(not defined $DB->{"APIReport_D"}{$V1}{$V2}
    and not keys(%Added) and not keys(%Removed))
    {
        rmtree($Dir);
        return;
    }
    
    my $Report = "";
    
    $Report .= getHead("archives_report");
    $Report .= "<h1>Archives API report: <span class='version'>$V1</span> vs <span class='version'>$V2</span></h1>\n"; # API changes report
    $Report .= "<br/>\n";
    $Report .= "<br/>\n";
    
    $Report .= "<!-- content -->\n";
    $Report .= "<table class='summary'>\n";
    $Report .= "<tr>";
    $Report .= "<th rowspan='2'>Archive</th>\n";
    if($Profile->{"CompatRate"} ne "Off") {
        $Report .= "<th colspan='2'>Backward<br/>Compatibility</th>\n";
    }
    $Report .= "<th rowspan='2'>Added<br/>Methods</th>\n";
    $Report .= "<th rowspan='2'>Removed<br/>Methods</th>\n";
    if($Profile->{"ShowTotalProblems"} eq "On") {
        $Report .= "<th colspan='2'>Total<br/>Changes</th>\n";
    }
    $Report .= "</tr>\n";
    
    if($Profile->{"CompatRate"} ne "Off" or $Profile->{"ShowTotalProblems"} eq "On")
    {
        $Report .= "<tr>";
        
        if($Profile->{"CompatRate"} ne "Off")
        {
            $Report .= "<th title='Binary compatibility' class='bc'>BC</th>\n";
            $Report .= "<th title='Source compatibility' class='sc'>SC</th>\n";
        }
        
        if($Profile->{"ShowTotalProblems"} eq "On")
        {
            $Report .= "<th title='Binary compatibility' class='bc'>BC</th>\n";
            $Report .= "<th title='Source compatibility' class='sc'>SC</th>\n";
        }
        
        $Report .= "</tr>\n";
    }
    
    my $MPrefix = getMaxPrefix(@Archives1, @Archives2);
    my $Analyzed = 0;
    
    foreach my $Archive2 (@Archives2)
    {
        my $Name = $Archive2;
        
        if($MPrefix) {
            $Name=~s/\A\Q$MPrefix\E\///;
        }
        
        $Name=~s/\A(share|dist|jars|jmods)\///;
        $Name=~s/\Alib(64|32|)\///;
        
        if($Profile->{"ReportStyle"} eq "ShortArchive") {
            $Name = getArchiveName($Name, "Short");
        }
        
        if(defined $Added{$Archive2})
        {
            if($Profile->{"HideUncheked"})
            {
                if(not countSymbolsF($ArchiveDump{2}{$Archive2}, $V2))
                {
                    delete($Added{$Archive2});
                    next;
                }
            }
            
            $Report .= "<tr>\n";
            $Report .= "<td class='archive'>$Name</td>\n";
            $Report .= "<td colspan=\'$Cols\' class='added'>Added to package</td>\n";
            $Report .= "</tr>\n";
            
            $Analyzed += 1;
        }
    }
    
    if($Profile->{"ReportStyle"} eq "ShortArchive") {
        @Archives1 = sort {getArchiveName($a, "Short") cmp getArchiveName($b, "Short")} @Archives1;
    }
    
    foreach my $Archive1 (@Archives1)
    {
        if(skipArchive($Archive1)) {
            next;
        }
        
        my $Name = $Archive1;
        
        if($MPrefix) {
            $Name=~s/\A\Q$MPrefix\E\///;
        }
        
        $Name=~s/\A(share|dist|jars|jmods)\///;
        $Name=~s/\Alib(64|32|)\///;
        
        if($Profile->{"ReportStyle"} eq "ShortArchive") {
            $Name = getArchiveName($Name, "Short");
        }
        
        if($Mapped{$Archive1})
        {
            if(defined $RenamedArchive{$Archive1})
            {
                $Name .= "<br/>";
                $Name .= "<br/>";
                $Name .= "<span class='incompatible'>(changed file name from<br/>\"".getFilename($Archive1)."\"<br/>to<br/>\"".$RenamedArchive{$Archive1}."\")</span>";
            }
        }
        
        if($Mapped{$Archive1})
        {
            my $Md5 = getMd5($Archive1, $Mapped{$Archive1});
            
            if($Profile->{"HideUncheked"})
            {
                if(not defined $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}) {
                    next;
                }
            }
            
            $Report .= "<tr>\n";
            $Report .= "<td class='archive'>$Name</td>\n";
            
            if(defined $DB->{"APIReport_D"}{$V1}{$V2}{$Md5})
            {
                my $APIReport_D = $DB->{"APIReport_D"}{$V1}{$V2}{$Md5};
                
                my $BC_D = 100 - $APIReport_D->{"Affected"};
                my $AddedSymbols = $APIReport_D->{"Added"};
                my $RemovedSymbols = $APIReport_D->{"Removed"};
                my $TotalProblems = $APIReport_D->{"TotalProblems"};
                
                my $BC_D_Source = 100 - $APIReport_D->{"Source_Affected"};
                my $TotalProblems_Source = $APIReport_D->{"Source_TotalProblems"};
                
                my $Changed = ($AddedSymbols or $RemovedSymbols or $TotalProblems or $TotalProblems_Source);
                
                if($Profile->{"CompatRate"} ne "Off")
                {
                    my $CClass = "ok";
                    if($BC_D eq "100")
                    {
                        if($TotalProblems) {
                            $CClass = "warning";
                        }
                    }
                    else
                    {
                        if(int($BC_D)>=90) {
                            $CClass = "warning";
                        }
                        elsif(int($BC_D)>=80) {
                            $CClass = "almost_compatible";
                        }
                        else {
                            $CClass = "incompatible";
                        }
                    }
                    $Report .= "<td class=\'$CClass\'>";
                    if(not $Changed and $Profile->{"HideEmpty"}) {
                        $Report .= formatNum($BC_D)."%";
                    }
                    else {
                        $Report .= "<a href='../../../../".$APIReport_D->{"WWWPath"}."'>".formatNum($BC_D)."%</a>";
                    }
                    $Report .= "</td>\n";
                    
                    my $CClass_Source = "ok";
                    if($BC_D_Source eq "100")
                    {
                        if($TotalProblems_Source) {
                            $CClass_Source = "warning";
                        }
                    }
                    else
                    {
                        if(int($BC_D_Source)>=90) {
                            $CClass_Source = "warning";
                        }
                        elsif(int($BC_D_Source)>=80) {
                            $CClass_Source = "almost_compatible";
                        }
                        else {
                            $CClass_Source = "incompatible";
                        }
                    }
                    
                    $Report .= "<td class=\'$CClass_Source\'>";
                    if(not $Changed and $Profile->{"HideEmpty"}) {
                        $Report .= formatNum($BC_D_Source)."%";
                    }
                    else {
                        $Report .= "<a href='../../../../".$APIReport_D->{"WWWSource_ReportPath"}."'>".formatNum($BC_D_Source)."%</a>";
                    }
                    $Report .= "</td>\n";
                }
                
                if($AddedSymbols) {
                    $Report .= "<td class='added'><a$LinkClass href='../../../../".$APIReport_D->{"WWWPath"}."#Added'>".$AddedSymbols.$LinkNew."</a></td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
                
                if($RemovedSymbols) {
                    $Report .= "<td class='removed'><a$LinkClass href='../../../../".$APIReport_D->{"WWWPath"}."#Removed'>".$RemovedSymbols.$LinkRemoved."</a></td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
                
                if($Profile->{"ShowTotalProblems"} eq "On")
                {
                    if($TotalProblems) {
                        $Report .= "<td class=\'warning\'><a$LinkClass href='../../../../".$APIReport_D->{"WWWPath"}."'>$TotalProblems</a></td>\n";
                    }
                    else {
                        $Report .= "<td class='ok'>0</td>\n";
                    }
                    
                    if($TotalProblems_Source) {
                        $Report .= "<td class=\'warning\'><a$LinkClass href='../../../../".$APIReport_D->{"WWWSource_ReportPath"}."'>$TotalProblems_Source</a></td>\n";
                    }
                    else {
                        $Report .= "<td class='ok'>0</td>\n";
                    }
                }
            }
            else
            {
                foreach (1 .. $Cols) {
                    $Report .= "<td>N/A</td>\n";
                }
            }
            $Report .= "</tr>\n";
            
            $Analyzed += 1;
        }
        elsif(defined $Removed{$Archive1})
        {
            if($Profile->{"HideUncheked"})
            {
                if(not countSymbolsF($ArchiveDump{1}{$Archive1}, $V1))
                {
                    delete($Removed{$Archive1});
                    next;
                }
            }
            
            $Report .= "<tr>\n";
            $Report .= "<td class='archive'>$Name</td>\n";
            $Report .= "<td colspan=\'$Cols\' class='removed'>Removed from package</td>\n";
            $Report .= "</tr>\n";
            
            $Analyzed += 1;
        }
    }
    $Report .= "</table>\n";
    $Report .= "<!-- content end -->\n";
    
    if(not $Analyzed)
    {
        rmtree($Dir);
        return;
    }
    
    $Report .= getSign("Other");
    
    my $Title = showTitle().": Archives API report between $V1 and $V2 versions";
    my $Keywords = showTitle().", API, changes, compatibility, report";
    my $Desc = "API changes/compatibility report between $V1 and $V2 versions of the $TARGET_LIB";
    
    $Report = composeHTML_Head("archives_report", $Title, $Keywords, $Desc, "report.css")."\n<body>\n$Report\n</body>\n</html>\n";
    
    my $Output = $Dir."/report.html";
    
    writeFile($Output, $Report);
    
    my ($Affected_T, $AddedSymbols_T, $RemovedSymbols_T, $TotalProblems_T) = (0, 0, 0, 0);
    my ($Affected_T_Source, $TotalProblems_T_Source) = (0, 0);
    
    my $TotalFuncs = 0;
    
    foreach my $Ar (@Archives)
    {
        my $Md5 = getMd5($Ar, $Mapped{$Ar});
        if(defined $DB->{"APIReport_D"}{$V1}{$V2}{$Md5})
        {
            my $APIReport_D = $DB->{"APIReport_D"}{$V1}{$V2}{$Md5};
            my $Dump = $DB->{"APIDump"}{$V1}{getMd5($Ar)};
            my $Funcs = $Dump->{"TotalSymbols"};
            
            $Affected_T += $APIReport_D->{"Affected"} * $Funcs;
            $AddedSymbols_T += $APIReport_D->{"Added"};
            $RemovedSymbols_T += $APIReport_D->{"Removed"};
            $TotalProblems_T += $APIReport_D->{"TotalProblems"};
            
            $Affected_T_Source += $APIReport_D->{"Source_Affected"} * $Funcs;
            $TotalProblems_T_Source += $APIReport_D->{"Source_TotalProblems"};
            
            $TotalFuncs += $Funcs;
        }
    }
    
    my ($AddedByArchives_T, $RemovedByArchives_T) = (0, 0);
    
    foreach my $Ar (keys(%Added))
    {
        my $Dump = $DB->{"APIDump"}{$V2}{getMd5($Ar)};
        $AddedByArchives_T += countSymbolsF($Dump, $V2);
    }
    
    foreach my $Ar (keys(%Removed))
    {
        my $Dump = $DB->{"APIDump"}{$V1}{getMd5($Ar)};
        $RemovedByArchives_T += countSymbolsF($Dump, $V1);
    }
    
    my $BC = 100;
    if($TotalFuncs) {
        $BC -= $Affected_T/$TotalFuncs;
    }
    if(my $Rm = keys(%Removed) and $#Archives1>=0) {
        $BC *= (1-$RemovedByArchives_T/($TotalFuncs+$RemovedByArchives_T));
    }
    $BC = formatNum($BC);
    
    my $BC_Source = 100;
    if($TotalFuncs) {
        $BC_Source -= $Affected_T_Source/$TotalFuncs;
    }
    if(my $Rm = keys(%Removed) and $#Archives1>=0) {
        $BC_Source *= (1-$RemovedByArchives_T/($TotalFuncs+$RemovedByArchives_T));
    }
    $BC_Source = formatNum($BC_Source);
    
    $DB->{"APIReport"}{$V1}{$V2}{"Path"} = $Output;
    $DB->{"APIReport"}{$V1}{$V2}{"WWWPath"} = $Output;
    $DB->{"APIReport"}{$V1}{$V2}{"BC"} = $BC;
    $DB->{"APIReport"}{$V1}{$V2}{"Added"} = $AddedSymbols_T;
    $DB->{"APIReport"}{$V1}{$V2}{"Removed"} = $RemovedSymbols_T;
    $DB->{"APIReport"}{$V1}{$V2}{"TotalProblems"} = $TotalProblems_T;
    
    $DB->{"APIReport"}{$V1}{$V2}{"Source_BC"} = $BC_Source;
    $DB->{"APIReport"}{$V1}{$V2}{"Source_TotalProblems"} = $TotalProblems_T_Source;
    
    $DB->{"APIReport"}{$V1}{$V2}{"ArchivesAdded"} = keys(%Added);
    $DB->{"APIReport"}{$V1}{$V2}{"ArchivesRemoved"} = keys(%Removed);
    $DB->{"APIReport"}{$V1}{$V2}{"ArchivesAddedSymbols"} = $AddedByArchives_T;
    $DB->{"APIReport"}{$V1}{$V2}{"ArchivesRemovedSymbols"} = $RemovedByArchives_T;
    $DB->{"APIReport"}{$V1}{$V2}{"TotalArchives"} = $#Archives1 + 1;
    
    my @Meta = ();
    
    push(@Meta, "\"BC\": \"".$BC."\"");
    push(@Meta, "\"Added\": ".$AddedSymbols_T);
    push(@Meta, "\"Removed\": ".$RemovedSymbols_T);
    push(@Meta, "\"TotalProblems\": ".$TotalProblems_T);
    
    push(@Meta, "\"Source_BC\": ".$BC_Source);
    push(@Meta, "\"Source_TotalProblems\": ".$TotalProblems_T_Source);
    
    push(@Meta, "\"ArchivesAdded\": ".keys(%Added));
    push(@Meta, "\"ArchivesRemoved\": ".keys(%Removed));
    push(@Meta, "\"ArchivesAddedSymbols\": ".$AddedByArchives_T);
    push(@Meta, "\"ArchivesRemovedSymbols\": ".$RemovedByArchives_T);
    push(@Meta, "\"TotalArchives\": ".($#Archives1 + 1));
    
    writeFile($Dir."/meta.json", "{\n  ".join(",\n  ", @Meta)."\n}");
}

sub getMaxPrefix(@)
{
    my @Paths = @_;
    my %Prefix = ();
    
    foreach my $Path (@Paths)
    {
        my $P = getDirname($Path);
        do {
            $Prefix{$P}+=1;
        }
        while($P = getDirname($P));
    }
    
    my @ByCount = sort {$Prefix{$b}<=>$Prefix{$a}} keys(%Prefix);
    my $Max = $Prefix{$ByCount[0]};
    
    if($Max!=$#Paths+1) {
        return undef;
    }
    
    foreach my $P (sort {length($b)<=>length($a)} keys(%Prefix))
    {
        if($Prefix{$P}==$Max)
        {
            return $P;
        }
    }
    
    return undef;
}

sub getMd5(@)
{
    my $Md5 = md5_hex(@_);
    return substr($Md5, 0, $MD5_LEN);
}

sub compareAPIs($$$$)
{
    my ($V1, $V2, $Ar1, $Ar2) = @_;
    
    my $Md5 = getMd5($Ar1, $Ar2);
    
    if(not $In::Opt{"Rebuild"})
    {
        if(defined $DB->{"APIReport_D"}{$V1}{$V2}
        and defined $DB->{"APIReport_D"}{$V1}{$V2}{$Md5})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    printMsg("INFO", "Creating JAPICC report for $Ar1 ($V1) and $Ar2 ($V2)");
    
    my $TmpDir = $TMP_DIR."/apicc/";
    mkpath($TmpDir);
    
    my $Dump1 = $DB->{"APIDump"}{$V1}{getMd5($Ar1)};
    my $Dump2 = $DB->{"APIDump"}{$V2}{getMd5($Ar2)};
    
    if(not -e $Dump1->{"Path"})
    {
        printMsg("ERROR", "failed to find \'".$Dump1->{"Path"}."\'");
        return 1;
    }
    
    if(not -e $Dump2->{"Path"})
    {
        printMsg("ERROR", "failed to find \'".$Dump2->{"Path"}."\'");
        return 1;
    }
    
    delete($DB->{"APIReport_D"}{$V1}{$V2}{$Md5});
    
    my $Dir = "compat_report/$TARGET_LIB/$V1/$V2/$Md5";
    my $BinReport = $Dir."/bin_compat_report.html";
    my $SrcReport = $Dir."/src_compat_report.html";
    
    my $Module = getArchiveName(getFilename($Ar1), "Short");
    if(not $Module) {
        $Module = getFilename($Ar1);
    }
    
    if($Module eq "classes"
    and $Profile->{"Versions"}{$V2}{"Source"}=~/\.aar\Z/)
    { # Support for Android
        $Module = "classes.jar (".showTitle().")";
    }
    
    my $Cmd = $JAPICC." -l \"$Module\" -binary -source -old \"".$Dump1->{"Path"}."\" -new \"".$Dump2->{"Path"}."\" -bin-report-path \"$BinReport\" -src-report-path \"$SrcReport\"";
    
    if(my $AccOpts = getJAPICC_Options($V2)) {
        $Cmd .= " ".$AccOpts;
    }
    
    if($Profile->{"Versions"}{$V2}{"AddedAnnotations"}) {
        $Cmd .= " -added-annotations";
    }
    
    if($Profile->{"ExternalCss"}) {
        $Cmd .= " -external-css css/japicc.css";
    }
    
    if($Profile->{"ExternalJs"}) {
        $Cmd .= " -external-js js/japicc.js";
    }
    
    if($Profile->{"CompactReport"}) {
        $Cmd .= " -compact";
    }
    
    if(my $Dep = $Profile->{"Dep"})
    {
        if($Dep ne $Module)
        {
            foreach my $M (keys(%{$DB->{"APIDump"}{$V1}}))
            {
                my $Attr = $DB->{"APIDump"}{$V1}{$M};
                if(getArchiveName($Attr->{"Archive"}, "Short") eq $Dep)
                {
                    $Cmd .= " -dep1 ".$Attr->{"Path"};
                    last;
                }
            }
            
            foreach my $M (keys(%{$DB->{"APIDump"}{$V2}}))
            {
                my $Attr = $DB->{"APIDump"}{$V2}{$M};
                if(getArchiveName($Attr->{"Archive"}, "Short") eq $Dep)
                {
                    $Cmd .= " -dep2 ".$Attr->{"Path"};
                    last;
                }
            }
        }
    }
    
    $Cmd .= " -limit-affected 5";
    
    if($In::Opt{"Debug"}) {
        printMsg("DEBUG", "executing $Cmd");
    }
    
    qx/$Cmd/; # execute
    
    if(not -e $BinReport
    or not -e $SrcReport)
    {
        rmtree($TmpDir);
        rmtree($Dir);
        return;
    }
    
    my $Line = readLineNum($BinReport, 0);
    
    my ($CheckedMethods, $CheckedTypes) = ();
    if($Line=~/checked_methods:(.+?);/) {
        $CheckedMethods = $1;
    }
    if($Line=~/checked_types:(.+?);/) {
        $CheckedTypes = $1;
    }
    
    if(not $CheckedMethods or not $CheckedTypes)
    {
        printMsg("WARNING", "zero methods or types checked");
        
        rmtree($TmpDir);
        rmtree($Dir);
        return;
    }
    
    my ($Affected, $Added, $Removed) = ();
    my $Total = 0;
    
    if($Line=~/affected:(.+?);/) {
        $Affected = $1;
    }
    if($Line=~/added:(.+?);/) {
        $Added = $1;
    }
    if($Line=~/removed:(.+?);/) {
        $Removed = $1;
    }
    while($Line=~s/(\w+_problems_\w+|changed_constants):(.+?);//) {
        $Total += $2;
    }
    
    my ($Affected_Source) = ();
    my $Total_Source = 0;
    
    my $SrcLine = readLineNum($SrcReport, 0);
    if($SrcLine=~/affected:(.+?);/) {
        $Affected_Source = $1;
    }
    while($SrcLine=~s/\w+_problems_\w+:(.+?);//) {
        $Total_Source += $1;
    }
    
    my %Meta = ();
    
    $Meta{"Affected"} = $Affected;
    $Meta{"Added"} = $Added;
    $Meta{"Removed"} = $Removed;
    $Meta{"TotalProblems"} = $Total;
    $Meta{"Path"} = $BinReport;
    $Meta{"WWWPath"} = $BinReport;
    
    $Meta{"Source_Affected"} = $Affected_Source;
    $Meta{"Source_TotalProblems"} = $Total_Source;
    $Meta{"Source_ReportPath"} = $SrcReport;
    $Meta{"WWWSource_ReportPath"} = $SrcReport;
    
    $Meta{"Archive1"} = $Ar1;
    $Meta{"Archive2"} = $Ar2;
    
    $DB->{"APIReport_D"}{$V1}{$V2}{$Md5} = \%Meta;
    
    my @Meta = ();
    
    push(@Meta, "\"Affected\": \"".$Affected."\"");
    push(@Meta, "\"Added\": ".$Added);
    push(@Meta, "\"Removed\": ".$Removed);
    push(@Meta, "\"TotalProblems\": ".$Total);
    push(@Meta, "\"Source_Affected\": \"".$Affected_Source."\"");
    push(@Meta, "\"Source_TotalProblems\": \"".$Total_Source."\"");
    push(@Meta, "\"Source_ReportPath\": \"".$SrcReport."\"");
    push(@Meta, "\"Archive1\": \"".$Ar1."\"");
    push(@Meta, "\"Archive2\": \"".$Ar2."\"");
    
    writeFile($Dir."/meta.json", "{\n  ".join(",\n  ", @Meta)."\n}");
    
    my $Changed = ($Added or $Removed or $Total or $Total_Source);
    
    if(not $Changed and $Profile->{"HideEmpty"})
    {
        unlink($SrcReport);
        unlink($BinReport);
    }
    
    rmtree($TmpDir);
}

sub getJAPICC_Options($)
{
    my $V = $_[0];
    my @Opts = ();
    
    if(my $SkipPackages = $Profile->{"SkipPackages"}) {
        push(@Opts, "-skip-packages \"$SkipPackages\"");
    }
    
    if(my $SkipClasses = $Profile->{"SkipClasses"}) {
        push(@Opts, "-skip-classes \"$SkipClasses\"");
    }
    
    if(my $NonImpl = $Profile->{"NonImpl"}) {
        push(@Opts, "-non-impl \"$NonImpl\"");
    }
    
    if($Profile->{"NonImplAll"} eq "On") {
        push(@Opts, "-non-impl-all");
    }
    
    if(my $SkipInternalPackages = $Profile->{"SkipInternalPackages"}) {
        push(@Opts, "-skip-internal-packages \"$SkipInternalPackages\"");
    }
    
    if(my $SkipInternalTypes = $Profile->{"SkipInternalTypes"}) {
        push(@Opts, "-skip-internal-types \"$SkipInternalTypes\"");
    }
    
    if(my $CheckPackages = $Profile->{"CheckPackages"}) {
        push(@Opts, "-check-packages \"$CheckPackages\"");
    }
    
    if(not $Profile->{"Versions"}{$V}{"WithoutAnnotations"})
    {
        if(my $AnnotationList = $Profile->{"AnnotationList"}) {
            push(@Opts, "-annotations-list \"$AnnotationList\"");
        }
        
        if(my $SkipAnnotationList = $Profile->{"SkipAnnotationList"}) {
            push(@Opts, "-skip-annotations-list \"$SkipAnnotationList\"");
        }
    }
    
    if(my $DumpOpts = getDump_Options()) {
        push(@Opts, $DumpOpts);
    }
    
    return join(" ", @Opts);
}

sub getDump_Options()
{
    my @Opts = ();
    
    if($Profile->{"KeepInternal"} eq "On") {
        push(@Opts, "--keep-internal");
    }
    
    if(my $JdkPath = $Profile->{"JdkPath"}) {
        push(@Opts, "-jdk-path", $JdkPath);
    }
    
    return join(" ", @Opts);
}

sub createPkgdiff($$)
{
    my ($V1, $V2) = @_;
    
    if($Profile->{"Versions"}{$V2}{"PkgDiff"} ne "On"
    and not (defined $In::Opt{"TargetVersion"} and defined $In::Opt{"TargetElement"})) {
        return 0;
    }
    
    if(not $In::Opt{"Rebuild"})
    {
        if(defined $DB->{"PackageDiff"}{$V1}{$V2}) {
            return 0;
        }
    }
    
    printMsg("INFO", "Creating package diff for $V1 and $V2");
    
    my $Source1 = $Profile->{"Versions"}{$V1}{"Source"};
    my $Source2 = $Profile->{"Versions"}{$V2}{"Source"};
    
    if(not -e $Source1) {
        return 1;
    }
    
    if(not -e $Source2) {
        return 1;
    }
    
    delete($DB->{"PackageDiff"}{$V1}{$V2});
    
    my $Dir = "package_diff/$TARGET_LIB/$V1/$V2";
    my $Output = $Dir."/report.html";
    rmtree($Dir);
    
    my $Cmd = $PKGDIFF." -report-path \"$Output\" \"$Source1\" \"$Source2\"";
    my $Log = `$Cmd`; # execute
    
    if(-f $Output)
    {
        $DB->{"PackageDiff"}{$V1}{$V2}{"Path"} = $Output;
        
        if($Log=~/CHANGED\s*\((.+?)\%\)/) {
            $DB->{"PackageDiff"}{$V1}{$V2}{"Changed"} = $1;
        }
    }
}

sub showTitle()
{
    if(defined $Profile->{"Title"}) {
        return $Profile->{"Title"};
    }
    
    return $TARGET_LIB;
}

sub getHead($)
{
    my $Sel = $_[0];
    
    my $UrlPr = getTop($Sel);
    
    my $ReportHeader = "API<br/>Tracker 4J";
    if(defined $Profile->{"ReportHeader"}) {
        $ReportHeader = $Profile->{"ReportHeader"};
    }
    
    my $Head = "";
    
    $Head .= "<table cellpadding='0' cellspacing='0'>";
    $Head .= "<tr>";
    
    $Head .= "<td align='center'>";
    
    if($TARGET_LIB) {
        $Head .= "<h1 class='tool'><a title=\'Home: API tracker for ".showTitle()."\' href='$UrlPr/timeline/$TARGET_LIB/index.html' class='tool'>".$ReportHeader."</a></h1>";
    }
    else {
        $Head .= "<h1 class='tool'><a title='Home: API tracker' href='' class='tool'>".$ReportHeader."</a></h1>";
    }
    $Head .= "</td>";
    
    if(not defined $Profile->{"ReportHeader"})
    {
        $Head .= "<td width='30px;'>";
        $Head .= "</td>";
        
        if($Sel ne "global_index")
        {
            $Head .= "<td>";
            $Head .= "<h1>(".showTitle().")</h1>";
            $Head .= "</td>";
        }
    }
    
    $Head .= "</tr></table>";
    
    $Head .= "<hr/>\n";
    $Head .= "<br/>\n";
    $Head .= "<br/>\n";
    
    return $Head;
}

sub getSign($)
{
    my $T = $_[0];
    
    my $Sign = "";
    
    $Sign .= "<br/>\n";
    $Sign .= "<br/>\n";
    
    $Sign .= "<hr/>\n";
    
    if($T eq "Home") {
        $Sign .= "<div align='right'><a class='home' title=\"Andrey Ponomarenko's ABI laboratory\" href='".$HomePage."'>abi-laboratory.pro</a></div>\n";
    }
    else {
        $Sign .= "<div align='right'><a class='home' title=\"Andrey Ponomarenko's ABI laboratory\" href='https://github.com/lvc'>github.com/lvc</a></div>\n";
    }
    
    $Sign .= "<br/>\n";
    
    return $Sign;
}

sub getVersionsList()
{
    my @Versions = keys(%{$Profile->{"Versions"}});
    @Versions = sort {int($Profile->{"Versions"}{$a}{"Pos"})<=>int($Profile->{"Versions"}{$b}{"Pos"})} @Versions;
    
    if(my $Minimal = $Profile->{"MinimalVersion"})
    {
        if(defined $Profile->{"Versions"}{$Minimal})
        {
            my $MinPos = $Profile->{"Versions"}{$Minimal}{"Pos"};
            my @Part = ();
            
            foreach (@Versions)
            {
                if($Profile->{"Versions"}{$_}{"Pos"}<=$MinPos) {
                    push(@Part, $_);
                }
            }
            
            @Versions = @Part;
        }
    }
    
    return @Versions;
}

sub writeCss()
{
    writeFile("css/common.css", readModule("Styles", "Common.css"));
    writeFile("css/report.css", readModule("Styles", "Report.css"));
    writeFile("css/changelog.css", readModule("Styles", "Changelog.css"));
}

sub writeJs()
{
    writeFile("js/index.js", readModule("Js", "Index.js"));
}

sub writeImages()
{
    my $ImgDir = $MODULES_DIR."/Internals/Images";
    if(not -d "images/") {
        mkpath("images/");
    }
    foreach my $Img (listDir($ImgDir)) {
        copy($ImgDir."/".$Img, "images/");
    }
}

sub createTimeline()
{
    $DB->{"Updated"} = time;
    
    writeCss();
    writeJs();
    writeImages();
    
    my $Title = showTitle().": API changes review";
    my $Desc = "API compatibility analysis reports for ".showTitle();
    my $Content = composeHTML_Head("timeline", $Title, $TARGET_LIB.", API, compatibility, report", $Desc, "report.css");
    $Content .= "<body>\n";
    
    my @Rss = ();
    my $RssLink = $HomePage."java/tracker/timeline/$TARGET_LIB";
    
    my @Versions = getVersionsList();
    
    if(not @Versions) {
        return;
    }
    
    my $CompatRate = "On";
    my $Changelog = "Off";
    my $PkgDiff = "Off";
    my $ShowDate = "On";
    
    if($Profile->{"CompatRate"} eq "Off") {
        $CompatRate = "Off";
    }
    
    if($Profile->{"Date"} eq "Off") {
        $ShowDate = "Off";
    }
    
    foreach my $V (@Versions)
    {
        if($Profile->{"Versions"}{$V}{"Changelog"} ne "Off")
        {
            $Changelog = "On";
        }
        
        if($Profile->{"Versions"}{$V}{"PkgDiff"} eq "On")
        {
            $PkgDiff = "On";
        }
    }
    
    my $Cols = 10;
    
    if($CompatRate eq "Off") {
        $Cols-=2;
    }
    
    if($Profile->{"ShowTotalProblems"} ne "On") {
        $Cols-=2;
    }
    
    if($Changelog eq "Off") {
        $Cols-=1;
    }
    
    if($PkgDiff eq "Off") {
        $Cols-=1;
    }
    
    if($ShowDate eq "Off") {
        $Cols-=1;
    }
    
    $Content .= getHead("timeline");
    
    my $ContentHeader = "API changes review";
    if(defined $Profile->{"ContentHeader"}) {
        $ContentHeader = $Profile->{"ContentHeader"};
    }
    
    if($In::Opt{"GenRss"}) {
        $ContentHeader .= " <a rel='alternate' type='application/rss+xml' href='../../rss/$TARGET_LIB/feed.rss' title='RSS: subscribe for API reports'><img src='../../images/RSS.png' class='rss' alt='RSS' /></a>";
    }
    
    $Content .= "<h1>".$ContentHeader."</h1>\n";
    
    my $GraphPath = "graph/$TARGET_LIB/graph.svg";
    my $ShowGraph = (-f $GraphPath);
    my $ShowSponsor = (defined $In::Opt{"Sponsors"} and defined $LibrarySponsor{$TARGET_LIB});
    
    $Content .= "<!-- content -->\n";
    
    if($ShowGraph or $ShowSponsor)
    {
        if($ShowSponsor)
        {
            #if(not defined $LibrarySponsor{$TARGET_LIB})
            #{
            #    $Content .= "<div class='become_sponsor'>\n";
            #    $Content .= "Become a <a href='https://abi-laboratory.pro/index.php?view=sponsor-java'>sponsor</a><br/>of this report";
            #    $Content .= "</div>\n";
            #}
        }
        
        if($ShowGraph)
        {
            $Content .= "<p>\n";
            $Content .= "<img src=\'../../$GraphPath?v=1.1\' alt='Timeline of API changes' />\n";
            $Content .= "</p>\n";
        }
        
        if($ShowSponsor)
        {
            my %Weight = (
                "Bronze"  => 1,
                "Silver"  => 2,
                "Gold"    => 3,
                "Diamond" => 4,
                "Keystone" => 5
            );
            
            my $Sponsors = $LibrarySponsor{$TARGET_LIB};
            
            $Content .= "<p>\n";
            $Content .= "<div class='sponsor'>\n";
            $Content .= "This report is<br/>supported by<p/>\n";
            
            foreach my $SName (sort {$Weight{$Sponsors->{$b}{"Status"}}<=>$Weight{$Sponsors->{$a}{"Status"}}} sort keys(%{$Sponsors}))
            {
                my $Sponsor = $Sponsors->{$SName};
                my $Logo = $Sponsor->{"Logo"};
                
                $Content .= "<a href='".$Sponsor->{"Url"}."'>";
                
                if($Logo and -f $Logo) {
                    $Content .= "<img src=\'../../$Logo\' alt='".$SName."' class='sponsor' />";
                }
                else {
                    $Content .= $SName;
                }
                
                $Content .= "</a>\n";
            }
            $Content .= "</div>\n";
            $Content .= "</p>\n";
        }
    }
    else
    {
        $Content .= "<br/>\n";
    }
    
    $Content .= "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>\n";
    $Content .= "<th rowspan='2'>Version</th>\n";
    
    if($ShowDate ne "Off") {
        $Content .= "<th rowspan='2'>Date</th>\n";
    }
    
    if($Changelog ne "Off") {
        $Content .= "<th rowspan='2'>Change<br/>Log</th>\n";
    }
    
    if($CompatRate ne "Off") {
        $Content .= "<th colspan='2'>Backward<br/>Compatibility</th>\n";
    }
    
    $Content .= "<th rowspan='2'>Added<br/>Methods</th>\n";
    $Content .= "<th rowspan='2'>Removed<br/>Methods</th>\n";
    if($Profile->{"ShowTotalProblems"} eq "On") {
        $Content .= "<th colspan='2'>Total<br/>Changes</th>\n";
    }
    
    if($PkgDiff ne "Off") {
        $Content .= "<th rowspan='2'>Package<br/>Diff</th>\n";
    }
    
    $Content .= "</tr>\n";
    
    if($CompatRate ne "Off" or $Profile->{"ShowTotalProblems"} eq "On")
    {
        $Content .= "<tr>\n";
        
        if($CompatRate ne "Off")
        {
            $Content .= "<th title='Binary compatibility' class='bc'>BC</th>\n";
            $Content .= "<th title='Source compatibility' class='sc'>SC</th>\n";
        }
        
        if($Profile->{"ShowTotalProblems"} eq "On")
        {
            $Content .= "<th title='Binary compatibility' class='bc'>BC</th>\n";
            $Content .= "<th title='Source compatibility' class='sc'>SC</th>\n";
        }
        
        $Content .= "</tr>\n";
    }
    
    foreach my $P (0 .. $#Versions)
    {
        my $V = $Versions[$P];
        my $O_V = undef;
        if($P<$#Versions) {
            $O_V = $Versions[$P+1];
        }
        
        my $APIReport = undef;
        my $PackageDiff = undef;
        
        if(defined $DB->{"APIReport"} and defined $DB->{"APIReport"}{$O_V}
        and defined $DB->{"APIReport"}{$O_V}{$V}) {
            $APIReport = $DB->{"APIReport"}{$O_V}{$V};
        }
        if(defined $DB->{"PackageDiff"} and defined $DB->{"PackageDiff"}{$O_V}
        and defined $DB->{"PackageDiff"}{$O_V}{$V}) {
            $PackageDiff = $DB->{"PackageDiff"}{$O_V}{$V};
        }
        
        my $Date = "N/A";
        
        if(defined $DB->{"Date"} and defined $DB->{"Date"}{$V}) {
            $Date = $DB->{"Date"}{$V};
        }
        
        my $Anchor = $V;
        if($V ne "current") {
            $Anchor = "v".$Anchor;
        }
        
        my $SV = $V;
        if(isSnapshot($V, $Profile))
        {
            if(my $SnapVer = getSnapshotVer($V, $Profile)) {
                $SV .= "<br/>(".$SnapVer.")";
            }
        }
        
        $Content .= "<tr id='".$Anchor."'>";
        
        $Content .= "<td title='".getFilename($Profile->{"Versions"}{$V}{"Source"})."'>".$SV."</td>\n";
        
        if($ShowDate ne "Off") {
            $Content .= "<td>".showDate($V, $Date)."</td>\n";
        }
        
        if($Changelog ne "Off")
        {
            my $Chglog = $DB->{"Changelog"}{$V};
            
            if($Chglog and $Chglog ne "Off"
            and $Profile->{"Versions"}{$V}{"Changelog"} ne "Off") {
                $Content .= "<td><a href=\'../../".$Chglog."\'>changelog</a></td>\n";
            }
            elsif(index($Profile->{"Versions"}{$V}{"Changelog"}, "://")!=-1) {
                $Content .= "<td><a href=\'".$Profile->{"Versions"}{$V}{"Changelog"}."\'>changelog</a></td>\n";
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if($CompatRate ne "Off")
        {
            if(defined $APIReport)
            {
                my $BC = $APIReport->{"BC"};
                my $ArchivesAdded = $APIReport->{"ArchivesAdded"};
                my $ArchivesRemoved = $APIReport->{"ArchivesRemoved"};
                my $TotalProblems = $APIReport->{"TotalProblems"};
                
                my $BC_Source = $APIReport->{"Source_BC"};
                my $TotalProblems_Source = $APIReport->{"Source_TotalProblems"};
                
                my @Note = ();
                
                if($ArchivesAdded) {
                    push(@Note, "<span class='added'>added $ArchivesAdded module".getS($ArchivesAdded)."</span>");
                }
                
                if($ArchivesRemoved) {
                    push(@Note, "<span class='incompatible'>removed $ArchivesRemoved module".getS($ArchivesRemoved)."</span>");
                }
                
                my $CClass = "ok";
                if($BC ne "100")
                {
                    if(int($BC)>=90) {
                        $CClass = "warning";
                    }
                    elsif(int($BC)>=80) {
                        $CClass = "almost_compatible";
                    }
                    else {
                        $CClass = "incompatible";
                    }
                }
                elsif($TotalProblems) {
                    $CClass = "warning";
                }
                
                my $BC_Summary = "<a href='../../".$APIReport->{"WWWPath"}."'>$BC%</a>";
                
                my $CClass_Source = "ok";
                if($BC_Source ne "100")
                {
                    if(int($BC_Source)>=90) {
                        $CClass_Source = "warning";
                    }
                    elsif(int($BC_Source)>=80) {
                        $CClass_Source = "almost_compatible";
                    }
                    else {
                        $CClass_Source = "incompatible";
                    }
                }
                elsif($TotalProblems_Source) {
                    $CClass_Source = "warning";
                }
                
                my $BC_Summary_Source = "<a href='../../".$APIReport->{"WWWPath"}."'>$BC_Source%</a>";
                
                if(@Note)
                {
                    $BC_Summary .= "<br/>\n";
                    $BC_Summary .= "<br/>\n";
                    $BC_Summary .= "<span class='note'>".join("<br/>", @Note)."</span>\n";
                }
                
                if($BC_Summary eq $BC_Summary_Source and $CClass eq $CClass_Source) {
                    $Content .= "<td colspan='2' class=\'$CClass\'>$BC_Summary</td>\n";
                }
                else
                {
                    $Content .= "<td class=\'$CClass\'>$BC_Summary</td>\n";
                    $Content .= "<td class=\'$CClass_Source\'>$BC_Summary_Source</td>\n";
                }
            }
            else
            {
                $Content .= "<td>N/A</td>\n";
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if(defined $APIReport)
        {
            if(my $Added = $APIReport->{"Added"}) {
                $Content .= "<td class='added'><a$LinkClass href='../../".$APIReport->{"WWWPath"}."'>".$Added.$LinkNew."</a></td>\n";
            }
            else {
                $Content .= "<td class='ok'>0</td>\n";
            }
        }
        else {
            $Content .= "<td>N/A</td>\n";
        }
        
        if(defined $APIReport)
        {
            if(my $Removed = $APIReport->{"Removed"}) {
                $Content .= "<td class='removed'><a$LinkClass href='../../".$APIReport->{"WWWPath"}."'>".$Removed.$LinkRemoved."</a></td>\n";
            }
            else {
                $Content .= "<td class='ok'>0</td>\n";
            }
        }
        else {
            $Content .= "<td>N/A</td>\n";
        }
        
        if($Profile->{"ShowTotalProblems"} eq "On")
        {
            if(defined $APIReport)
            {
                if(my $TotalProblems = $APIReport->{"TotalProblems"}) {
                    $Content .= "<td class=\'warning\'><a$LinkClass href='../../".$APIReport->{"WWWPath"}."'>$TotalProblems</a></td>\n";
                }
                else {
                    $Content .= "<td class='ok'>0</td>\n";
                }
                
                if(my $TotalProblems_Source = $APIReport->{"Source_TotalProblems"}) {
                    $Content .= "<td class=\'warning\'><a$LinkClass href='../../".$APIReport->{"WWWPath"}."'>$TotalProblems_Source</a></td>\n";
                }
                else {
                    $Content .= "<td class='ok'>0</td>\n";
                }
            }
            else {
                $Content .= "<td>N/A</td>\n";
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if($PkgDiff ne "Off")
        {
            if(defined $PackageDiff and $Profile->{"Versions"}{$V}{"PkgDiff"} eq "On")
            {
                if(my $Changed = $PackageDiff->{"Changed"}) {
                    $Content .= "<td><a href='../../".$PackageDiff->{"Path"}."'>$Changed%</a></td>\n";
                }
                else {
                    $Content .= "<td>0</td>\n";
                }
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        $Content .= "</tr>\n";
        
        if(my $Comment = $Profile->{"Versions"}{$V}{"Comment"})
        {
            $Content .= "<tr><td class='comment' colspan=\'$Cols\'>NOTE: $Comment</td></tr>\n";
        }
        
        if($In::Opt{"GenRss"} and defined $APIReport and $V ne "current" and not isSnapshot($V, $Profile))
        {
            my @RssSum = ("Binary compatibility: ".$APIReport->{"BC"}."%");
            if(my $TotalProblems = $APIReport->{"TotalProblems"})
            {
                if($APIReport->{"BC"} eq 100) {
                    push(@RssSum, "$TotalProblems warning".getS($TotalProblems));
                }
                else {
                    push(@RssSum, "$TotalProblems problem".getS($TotalProblems));
                }
            }
            if(my $ArchivesAdded = $APIReport->{"ArchivesAdded"}) {
                push(@RssSum, "added $ArchivesAdded module".getS($ArchivesAdded));
            }
            if(my $ArchivesRemoved = $APIReport->{"ArchivesRemoved"}) {
                push(@RssSum, "removed $ArchivesRemoved module".getS($ArchivesRemoved));
            }
            if(my $Added = $APIReport->{"Added"}) {
                push(@RssSum, "added $Added method".getS($Added));
            }
            if(my $Removed = $APIReport->{"Removed"}) {
                push(@RssSum, "removed $Removed method".getS($Removed));
            }
            
            my $Desc = join(", ", @RssSum).".";
            
            my @RssSum_Source = ("Source compatibility: ".$APIReport->{"Source_BC"}."%");
            
            if(my $TotalProblems_Source = $APIReport->{"Source_TotalProblems"})
            {
                if($APIReport->{"Source_BC"} eq 100) {
                    push(@RssSum_Source, "$TotalProblems_Source warning".getS($TotalProblems_Source));
                }
                else {
                    push(@RssSum_Source, "$TotalProblems_Source problem".getS($TotalProblems_Source));
                }
            }
            
            $Desc .= " ".join(", ", @RssSum_Source).".";
            
            my $RssItem = "<item>\n";
            $RssItem .= "    <title>".showTitle()." $V</title>\n";
            $RssItem .= "    <link>$RssLink</link>\n";
            $RssItem .= "    <description>".$Desc."</description>\n";
            $RssItem .= "    <pubDate>".getRssDate($DB->{"Date"}{$V})."</pubDate>\n";
            $RssItem .= "</item>";
            
            $RssItem=~s/\n/\n    /gs;
            push(@Rss, "    ".$RssItem);
        }
    }
    
    $Content .= "</table>";
    
    $Content .= "<br/>";
    if(defined $Profile->{"Maintainer"})
    {
        my $M = $Profile->{"Maintainer"};
        
        if(defined $Profile->{"MaintainerUrl"}) {
            $M = "<a href='".$Profile->{"MaintainerUrl"}."'>$M</a>";
        }
        
        $Content .= "Maintained by $M. ";
    }
    
    my $UpdateTime = localtime($DB->{"Updated"});
    $UpdateTime=~s/(\d\d:\d\d):\d\d/$1/;
    
    $Content .= "Last updated on ".$UpdateTime.".";
    
    $Content .= "<br/>";
    $Content .= "<br/>";
    $Content .= "Generated by <a href='https://github.com/lvc/japi-tracker'>Java API Tracker</a> and <a href='https://github.com/lvc/japi-compliance-checker'>JAPICC</a> tools.";
    $Content .= "<!-- content end -->\n";
    
    $Content .= getSign("Home");
    
    $Content .= "</body></html>";
    
    my $Output = "timeline/".$TARGET_LIB."/index.html";
    writeFile($Output, $Content);
    printMsg("INFO", "The index has been generated to: $Output");
    
    if($In::Opt{"GenRss"})
    {
        my $RssFeed = "<?xml version='1.0' encoding='UTF-8' ?>\n";
        $RssFeed .= "<rss version='2.0'>\n\n";
        $RssFeed .= "<channel>\n";
        $RssFeed .= "<title>API changes review for ".showTitle()."</title>\n";
        $RssFeed .= "<link>$RssLink</link>\n";
        $RssFeed .= "<description>Binary compatibility analysis reports for ".showTitle()."</description>\n";
        $RssFeed .= join("\n", @Rss)."\n";
        $RssFeed .= "</channel>\n\n";
        $RssFeed .= "</rss>\n";
        
        writeFile("rss/".$TARGET_LIB."/feed.rss", $RssFeed);
    }
}

sub createJsonReport($)
{
    my $Dir = $_[0];
    
    if(not -d $Dir) {
        exitStatus("Access_Error", "can't access directory \'$Dir\'");
    }
    
    my $MaxLen_C = 9;
    my $MaxLen_V = 16;
    my @Common = ();
    
    my %ShowKey = (
        "Source_BC" => "Src_BC",
        "Source_TotalProblems" => "Src_TotalProblems"
    );
    
    foreach my $K ("Title", "SourceUrl", "Tracker", "Maintainer")
    {
        my $Sp = "";
        foreach (0 .. $MaxLen_C - length($K)) {
            $Sp .= " ";
        }
        
        my $Val = undef;
        
        if(defined $Profile->{$K}) {
            $Val = $Profile->{$K};
        }
        elsif($K eq "Tracker") {
            $Val = $HomePage."java/tracker/timeline/".$TARGET_LIB."/";
        }
        elsif($K eq "Title") {
            $Val = $TARGET_LIB;
        }
        
        if($Val) {
            push(@Common, "\"$K\": ".$Sp."\"$Val\"");
        }
    }
    
    my @RInfo = ();
    my @Versions = getVersionsList();
    
    foreach my $P (0 .. $#Versions)
    {
        my $V = $Versions[$P];
        
        if($V eq "current") {
            next;
        }
        
        my $O_V = undef;
        if($P<$#Versions) {
            $O_V = $Versions[$P+1];
        }
        
        if(defined $DB->{"APIReport"} and defined $DB->{"APIReport"}{$O_V}
        and defined $DB->{"APIReport"}{$O_V}{$V})
        {
            my $APIReport = $DB->{"APIReport"}{$O_V}{$V};
            my @VInfo = ();
            
            foreach my $K ("Version", "From", "BC", "Added", "Removed", "TotalProblems", "Source_BC", "Source_TotalProblems", "ArchivesAdded", "ArchivesRemoved", "TotalArchives")
            {
                my $Val = undef;
                
                if(defined $APIReport->{$K}) {
                    $Val = $APIReport->{$K};
                }
                elsif($K eq "Version") {
                    $Val = $V;
                }
                elsif($K eq "From") {
                    $Val = $O_V;
                }
                else {
                    next;
                }
                
                if($K eq "BC" or $K eq "Source_BC") {
                    $Val .= "%";
                }
                
                my $SK = $K;
                
                if(defined $ShowKey{$K}) {
                    $SK = $ShowKey{$K};
                }
                
                my $Sp = "";
                foreach (0 .. $MaxLen_V - length($SK)) {
                    $Sp .= " ";
                }
                
                if($K!~/BC|Version/ and int($Val) eq $Val)
                { # integer
                    push(@VInfo, "\"$SK\": $Sp".$Val);
                }
                else
                { # string
                    push(@VInfo, "\"$SK\": $Sp\"".$Val."\"");
                }
            }
            
            push(@RInfo, "{\n    ".join(",\n    ", @VInfo)."\n  }");
        }
    }
    
    my $Report = "{\n  ".join(",\n  ", @Common).",\n\n  \"Reports\": [\n  ".join(",\n  ", @RInfo)."]\n}\n";
    
    writeFile($Dir."/$TARGET_LIB.json", $Report);
}

sub createGlobalIndex()
{
    my @Libs = ();
    
    foreach my $File (listDir("timeline"))
    {
        if($File ne "index.html")
        {
            push(@Libs, $File);
        }
    }
    
    if($#Libs<=0)
    { # for two or more libraries
        #return 0;
    }
    
    writeCss();
    writeJs();
    writeImages();
    
    my $Title = "API Tracker: Tested Java libraries";
    my $Desc = "List of maintained libraries";
    my $Content = composeHTML_Head("global_index", $Title, "", $Desc, "report.css", "index.js");
    $Content .= "<body onload=\"applyFilter(document.getElementById('Filter'), 'List', 'Header', 'Note')\">\n";
    
    $Content .= getHead("global_index");
    
    $Content .= "<h1>Tested libraries (".($#Libs+1).")</h1>\n";
    $Content .= "<br/>\n";
    
    $Content .= "<!-- content -->\n";
    if($#Libs>=10)
    {
        my $E = "applyFilter(this, 'List', 'Header', 'Note')";
        
        $Content .= "<table cellpadding='0' cellspacing='0'>";
        $Content .= "<tr>\n";
        
        $Content .= "<td>\n";
        $Content .= "Filter:&nbsp;";
        $Content .= "</td>\n";
        
        $Content .= "<td valign='bottom'>\n";
        
        $Content .= "<textarea id='Filter' autofocus='autofocus' rows='1' cols='20' style='border:solid 1px black' name='search' onkeydown='if(event.keyCode == 13) {return false;}' onkeyup=\"$E\"></textarea>\n";
        $Content .= "</td>\n";
        
        $Content .= "</tr>\n";
        $Content .= "</table>\n";
        
        $Content .= "<div id='Note' style='display:none;visibility:hidden;'>\n";
        $Content .= "<p/>\n";
        $Content .= "<br/>\n";
        $Content .= "No info (<a href=\'$HomePage?view=abi-tracker\'>add</a> a library)\n";
        $Content .= "</div>\n";
    }
    
    $Content .= "<p/>\n";
    
    $Content .= "<table id='List' cellpadding='3' class='summary highlight list'>\n";
    
    $Content .= "<tr id='Header'>\n";
    $Content .= "<th>Name</th>\n";
    $Content .= "<th>API Changes<br/>Review</th>\n";
    # $Content .= "<th>Maintainer</th>\n";
    $Content .= "</tr>\n";
    
    my %LibAttr = ();
    foreach my $L (sort @Libs)
    {
        my $Title = $L;
        # my ($M, $MUrl);
        
        if(-f "profile/$L.json")
        {
            my $Pr = readProfile(readFile("profile/$L.json"));
            if(defined $Pr->{"Title"}) {
                $Title = $Pr->{"Title"};
            }
        }
        else
        {
            my $DB_P = "db/$L/$DB_NAME";
            if(-f $DB_P)
            {
                my $DB = eval(readFile($DB_P));
                
                if(defined $DB->{"Title"}) {
                    $Title = $DB->{"Title"};
                }
            }
        }
        
        $LibAttr{$L}{"Title"} = $Title;
        
        # $LibAttr{$L}{"Maintainer"} = $M;
        # $LibAttr{$L}{"MaintainerUrl"} = $MUrl;
    }
    
    foreach my $L (sort {lc($LibAttr{$a}{"Title"}) cmp lc($LibAttr{$b}{"Title"})} @Libs)
    {
        my $LUrl = "timeline/$L/index.html";
        
        $LUrl=~s/\+/\%2B/g;
        
        $Content .= "<tr onclick=\"document.location=\'$LUrl\'\">\n";
        $Content .= "<td>".$LibAttr{$L}{"Title"}."</td>\n";
        $Content .= "<td><a href=\'$LUrl\'>review</a></td>\n";
        
        # my $M = $LibAttr{$L}{"Maintainer"};
        # if(my $MUrl = $LibAttr{$L}{"MaintainerUrl"}) {
        #     $M = "<a href='".$MUrl."'>$M</a>";
        # }
        # $Content .= "<td>$M</td>\n";
        
        $Content .= "</tr>\n";
    }
    
    $Content .= "</table>";
    $Content .= "<!-- content end -->\n";
    
    $Content .= getSign("Other");
    $Content .= "</body></html>";
    
    my $Output = "index.html";
    writeFile($Output, $Content);
    printMsg("INFO", "The global index has been generated to: $Output");
}

sub showDate($$)
{
    my ($V, $Date) = @_;
    
    my ($D, $T) = ($Date, "");
    
    if($Date=~/(.+) (.+)/) {
        ($D, $T) = ($1, $2);
    }
    
    if($V eq "current")
    {
        $T=~s/\:\d+\Z//;
        return $D."<br/>".$T;
    }
    
    return $D;
}

sub readDB($)
{
    my $Path = $_[0];
    
    if(-f $Path)
    {
        my $P = eval(readFile($Path));
        
        if(not $P) {
            exitStatus("Error", "please remove 'use strict' from code and retry");
        }
        
        return $P;
    }
    
    return {};
}

sub writeDB($)
{
    my $Path = $_[0];
    writeFile($Path, Dumper($DB));
}

sub checkFiles()
{
    my $PkgDiffs = "package_diff/$TARGET_LIB";
    foreach my $V1 (listDir($PkgDiffs))
    {
        foreach my $V2 (listDir($PkgDiffs."/".$V1))
        {
            if(not defined $DB->{"PackageDiff"}{$V1}{$V2})
            {
                $DB->{"PackageDiff"}{$V1}{$V2}{"Path"} = $PkgDiffs."/".$V1."/".$V2."/report.html";
                
                my $Line = readLineNum($DB->{"PackageDiff"}{$V1}{$V2}{"Path"}, 0);
                
                if($Line=~/changed:(.+?);/) {
                    $DB->{"PackageDiff"}{$V1}{$V2}{"Changed"} = $1;
                }
            }
        }
    }
    
    my $Changelogs = "changelog/$TARGET_LIB";
    foreach my $V (listDir($Changelogs))
    {
        if(not defined $DB->{"Changelog"}{$V})
        {
            $DB->{"Changelog"}{$V} = $Changelogs."/".$V."/log.html";
        }
    }
    
    my $Dumps = "api_dump/$TARGET_LIB";
    foreach my $V (listDir($Dumps))
    {
        foreach my $Md5 (listDir($Dumps."/".$V))
        {
            if(not defined $DB->{"APIDump"}{$V}{$Md5})
            {
                my %Info = ();
                my $Dir = $Dumps."/".$V."/".$Md5;
                
                $Info{"Path"} = $Dir."/API.dump";
                
                if(-e $Info{"Path"}.".".$COMPRESS) {
                    $Info{"Path"} .= ".".$COMPRESS;
                }
                
                my $Meta = readProfile(readFile($Dir."/meta.json"));
                $Info{"Archive"} = $Meta->{"Archive"};
                # $Info{"Lang"} = $Meta->{"Lang"};
                $Info{"TotalSymbols"} = $Meta->{"TotalSymbols"};
                
                $DB->{"APIDump"}{$V}{$Md5} = \%Info;
            }
        }
    }
    
    my $APIReports_D = "compat_report/$TARGET_LIB";
    foreach my $V1 (listDir($APIReports_D))
    {
        foreach my $V2 (listDir($APIReports_D."/".$V1))
        {
            foreach my $Md5 (listDir($APIReports_D."/".$V1."/".$V2))
            {
                my $Dir = $APIReports_D."/".$V1."/".$V2."/".$Md5;
                my $MetaPath = $Dir."/meta.json";
                if(not defined $DB->{"APIReport_D"}{$V1}{$V2}{$Md5})
                {
                    my %Info = ();
                    
                    $Info{"Path"} = $Dir."/bin_compat_report.html";
                    $Info{"WWWPath"} = $Info{"Path"};
                    
                    if(-e $Info{"Path"}.".".$COMPRESS) {
                        $Info{"Path"} .= ".".$COMPRESS;
                    }
                    
                    my $Meta = readProfile(readFile($MetaPath));
                    $Info{"Affected"} = $Meta->{"Affected"};
                    $Info{"Added"} = $Meta->{"Added"};
                    $Info{"Removed"} = $Meta->{"Removed"};
                    $Info{"TotalProblems"} = $Meta->{"TotalProblems"};
                    
                    $Info{"Source_Affected"} = $Meta->{"Source_Affected"};
                    $Info{"Source_TotalProblems"} = $Meta->{"Source_TotalProblems"};
                    $Info{"Source_ReportPath"} = $Meta->{"Source_ReportPath"};
                    
                    $Info{"WWWSource_ReportPath"} = $Info{"Source_ReportPath"};
                    
                    if(-e $Info{"Source_ReportPath"}.".".$COMPRESS) {
                        $Info{"Source_ReportPath"} .= ".".$COMPRESS;
                    }
                    
                    $Info{"Archive1"} = $Meta->{"Archive1"};
                    $Info{"Archive2"} = $Meta->{"Archive2"};
                    
                    $DB->{"APIReport_D"}{$V1}{$V2}{$Md5} = \%Info;
                }
                else
                {
                    my $Info = $DB->{"APIReport_D"}{$V1}{$V2}{$Md5};
                    if(not -e $MetaPath) {
                        genMeta($MetaPath, $Info);
                    }
                    
                    if($Profile->{"HideEmpty"})
                    {
                        if(not $Info->{"Added"} and not $Info->{"Removed"}
                        and not $Info->{"TotalProblems"} and not $Info->{"Source_TotalProblems"})
                        {
                            if(-e $Info->{"Path"})
                            {
                                printMsg("INFO", "Removing ".$Info->{"Path"});
                                unlink($Info->{"Path"});
                            }
                            
                            if(-e $Info->{"Source_ReportPath"})
                            {
                                printMsg("INFO", "Removing ".$Info->{"Source_ReportPath"});
                                unlink($Info->{"Source_ReportPath"});
                            }
                        }
                    }
                }
            }
        }
    }
    
    my $APIReports = "archives_report/$TARGET_LIB";
    foreach my $V1 (listDir($APIReports))
    {
        foreach my $V2 (listDir($APIReports."/".$V1))
        {
            my $Dir = $APIReports."/".$V1."/".$V2;
            my $MetaPath = $Dir."/meta.json";
            if(not defined $DB->{"APIReport"}{$V1}{$V2})
            {
                my %Info = ();
                my $Dir = $APIReports."/".$V1."/".$V2;
                
                $Info{"Path"} = $Dir."/report.html";
                $Info{"WWWPath"} = $Info{"Path"};
                
                if(-e $Info{"Path"}.".".$COMPRESS) {
                    $Info{"Path"} .= ".".$COMPRESS;
                }
                
                my $Meta = readProfile(readFile($MetaPath));
                $Info{"BC"} = $Meta->{"BC"};
                $Info{"Added"} = $Meta->{"Added"};
                $Info{"Removed"} = $Meta->{"Removed"};
                $Info{"TotalProblems"} = $Meta->{"TotalProblems"};
                
                $Info{"Source_BC"} = $Meta->{"Source_BC"};
                $Info{"Source_TotalProblems"} = $Meta->{"Source_TotalProblems"};
                
                $Info{"ArchivesAdded"} = $Meta->{"ArchivesAdded"};
                $Info{"ArchivesRemoved"} = $Meta->{"ArchivesRemoved"};
                
                $DB->{"APIReport"}{$V1}{$V2} = \%Info;
            }
            else
            {
                if(not -e $MetaPath) {
                    genMeta($MetaPath, $DB->{"APIReport"}{$V1}{$V2});
                }
            }
        }
    }
}

sub genMeta($$)
{
    my ($MetaPath, $Data) = @_;
    
    printMsg("INFO", "Generating metadata $MetaPath");
    
    my @Meta = ();
    
    foreach my $K (sort keys(%{$Data}))
    {
        my $Val = $Data->{$K};
        
        if($Val=~/\A\d+\Z/) {
            push(@Meta, "\"$K\": $Val");
        }
        else {
            push(@Meta, "\"$K\": \"".$Val."\"");
        }
    }
    
    if(@Meta) {
        writeFile($MetaPath, "{\n  ".join(",\n  ", @Meta)."\n}");
    }
}

sub checkDB()
{
    foreach my $V1 (keys(%{$DB->{"PackageDiff"}}))
    {
        foreach my $V2 (keys(%{$DB->{"PackageDiff"}{$V1}}))
        {
            if(not -e $DB->{"PackageDiff"}{$V1}{$V2}{"Path"})
            {
                delete($DB->{"PackageDiff"}{$V1}{$V2});
                
                if(not keys(%{$DB->{"PackageDiff"}{$V1}})) {
                    delete($DB->{"PackageDiff"}{$V1});
                }
            }
        }
    }
    
    foreach my $V (keys(%{$DB->{"Changelog"}}))
    {
        if($DB->{"Changelog"}{$V} ne "Off")
        {
            if(not -e $DB->{"Changelog"}{$V}) {
                delete($DB->{"Changelog"}{$V});
            }
        }
    }
    
    foreach my $V (keys(%{$DB->{"APIDump"}}))
    {
        foreach my $Md5 (keys(%{$DB->{"APIDump"}{$V}}))
        {
            if(not -e $DB->{"APIDump"}{$V}{$Md5}{"Path"}) {
                delete($DB->{"APIDump"}{$V}{$Md5});
            }
        }
        
        if(not keys(%{$DB->{"APIDump"}{$V}})) {
            delete($DB->{"APIDump"}{$V});
        }
    }
    
    foreach my $V1 (keys(%{$DB->{"APIReport_D"}}))
    {
        foreach my $V2 (keys(%{$DB->{"APIReport_D"}{$V1}}))
        {
            foreach my $Md5 (keys(%{$DB->{"APIReport_D"}{$V1}{$V2}}))
            {
                if(not -e $DB->{"APIReport_D"}{$V1}{$V2}{$Md5}{"Path"})
                {
                    delete($DB->{"APIReport_D"}{$V1}{$V2}{$Md5});
                    
                    if(not keys(%{$DB->{"APIReport_D"}{$V1}{$V2}})) {
                        delete($DB->{"APIReport_D"}{$V1}{$V2});
                    }
                    
                    if(not keys(%{$DB->{"APIReport_D"}{$V1}})) {
                        delete($DB->{"APIReport_D"}{$V1});
                    }
                }
            }
            
            if(not keys(%{$DB->{"APIReport_D"}{$V1}{$V2}})) {
                delete($DB->{"APIReport_D"}{$V1}{$V2});
            }
        }
        
        if(not keys(%{$DB->{"APIReport_D"}{$V1}})) {
            delete($DB->{"APIReport_D"}{$V1});
        }
    }
    
    foreach my $V1 (keys(%{$DB->{"APIReport"}}))
    {
        foreach my $V2 (keys(%{$DB->{"APIReport"}{$V1}}))
        {
            if(not -e $DB->{"APIReport"}{$V1}{$V2}{"Path"})
            {
                delete($DB->{"APIReport"}{$V1}{$V2});
                
                if(not keys(%{$DB->{"APIReport"}{$V1}})) {
                    delete($DB->{"APIReport"}{$V1});
                }
            }
            
            if(not keys(%{$DB->{"APIReport"}{$V1}{$V2}})) {
                delete($DB->{"APIReport"}{$V1}{$V2});
            }
        }
        
        if(not keys(%{$DB->{"APIReport"}{$V1}})) {
            delete($DB->{"APIReport"}{$V1});
        }
    }
}

sub safeExit()
{
    chdir($ORIG_DIR);
    
    printMsg("INFO", "\nGot INT signal");
    printMsg("INFO", "Exiting");
    
    if($DB_PATH) {
        writeDB($DB_PATH);
    }
    exit(1);
}

sub getToolVer($)
{
    my $T = $_[0];
    return `$T -dumpversion`;
}

sub scenario()
{
    $Data::Dumper::Sortkeys = 1;
    
    $SIG{INT} = \&safeExit;
    
    if($In::Opt{"Rebuild"}) {
        $In::Opt{"Build"} = 1;
    }
    
    if($In::Opt{"Build"} and not $In::Opt{"TargetElement"} and not $In::Opt{"TargetVersion"})
    {
        $In::Opt{"GenRss"} = 1;
    }
    
    if($In::Opt{"TargetElement"})
    {
        if($In::Opt{"TargetElement"}!~/\A(date|dates|changelog|apidump|apireport|pkgdiff|packagediff|graph|archivesreport|compress)\Z/)
        {
            exitStatus("Error", "the value of -target option should be one of the following: date, changelog, apidump, apireport, pkgdiff, graph, archivesreport.");
        }
    }
    
    if($In::Opt{"TargetElement"} eq "archivesreport")
    {
        $In::Opt{"TargetElement"} = "apireport";
        $ArchivesReport = 1;
    }
    
    if($In::Opt{"DumpVersion"})
    {
        printMsg("INFO", $TOOL_VERSION);
        exit(0);
    }
    
    if($In::Opt{"Help"})
    {
        printMsg("INFO", $HelpMessage);
        exit(0);
    }
    
    if(-d "objects_report") {
        exitStatus("Error", "Can't execute inside the ABI tracker home directory");
    }
    
    # check API CC
    if(my $Version = getToolVer($JAPICC))
    {
        if(cmpVersions_S($Version, $JAPICC_VERSION)<0) {
            exitStatus("Module_Error", "the version of Java API Compliance Checker should be $JAPICC_VERSION or newer");
        }
    }
    else {
        exitStatus("Module_Error", "cannot find \'$JAPICC\'");
    }
    
    my @Reports = ("timeline", "package_diff", "changelog", "api_dump", "archives_report", "compat_report", "graph", "rss");
    
    if(my $Profile_Path = $ARGV[0])
    {
        if(not $Profile_Path) {
            exitStatus("Error", "profile path is not specified");
        }
        
        if(not -e $Profile_Path) {
            exitStatus("Access_Error", "can't access \'$Profile_Path\'");
        }
        
        $Profile = readProfile(readFile($Profile_Path));
        
        if(defined $Profile->{"ShowTotalChanges"}) {
            $Profile->{"ShowTotalProblems"} = $Profile->{"ShowTotalChanges"};
        }
        
        if($Profile->{"ReportStyle"} eq "SimpleLinks")
        {
            $LinkClass = "";
            $LinkNew = "";
            $LinkRemoved = "";
        }
        
        if(not $Profile->{"Name"}) {
            exitStatus("Error", "name of the library is not specified in profile");
        }
        
        foreach my $V (sort keys(%{$Profile->{"Versions"}}))
        {
            if($Profile->{"Versions"}{$V}{"Deleted"}
            and $Profile->{"Versions"}{$V}{"Deleted"} ne "Off")
            { # do not show this version in the report
                delete($Profile->{"Versions"}{$V});
                next;
            }
            
            if(skipVersion($V))
            {
                delete($Profile->{"Versions"}{$V});
                next;
            }
        }
        
        $TARGET_LIB = $Profile->{"Name"};
        $DB_PATH = "db/".$TARGET_LIB."/".$DB_NAME;
        
        if(my $SponsorsFile = $In::Opt{"Sponsors"})
        {
            if(not -f $SponsorsFile) {
                exitStatus("Access_Error", "can't access \'$SponsorsFile\'");
            }
            
            my $Supports = readProfile(readFile($SponsorsFile));
            my $CurDate = getDate();
            
            foreach my $N (sort {$a<=>$b} keys(%{$Supports->{"Supports"}}))
            {
                my $Support = $Supports->{"Supports"}{$N};
                my $Till = delete($Support->{"Till"});
                
                if(($Till cmp $CurDate) == -1) {
                    next;
                }
                
                my $Libs = delete($Support->{"Libraries"});
                
                foreach my $L (@{$Libs})
                {
                    if($L eq "*") {
                        $L = $TARGET_LIB;
                    }
                    $LibrarySponsor{$L}{$Support->{"Name"}} = $Support;
                }
            }
        }
        
        $In::Opt{"TargetLib"} = $TARGET_LIB;
        $In::Opt{"DBPath"} = $DB_PATH;
        
        if($In::Opt{"Clear"})
        {
            printMsg("INFO", "Remove $DB_PATH");
            unlink($DB_PATH);
            
            foreach my $Dir (@Reports)
            {
                printMsg("INFO", "Remove $Dir/$TARGET_LIB");
                rmtree($Dir."/".$TARGET_LIB);
            }
            exit(0);
        }
        
        $DB = readDB($DB_PATH);
        
        $DB->{"Maintainer"} = $Profile->{"Maintainer"};
        $DB->{"MaintainerUrl"} = $Profile->{"MaintainerUrl"};
        $DB->{"Title"} = $Profile->{"Title"};
        
        checkDB();
        checkFiles();
        
        if($In::Opt{"CleanUnused"}) {
            cleanUnused();
        }
        
        if($In::Opt{"Build"})
        {
            writeDB($DB_PATH);
            buildData();
        }
        
        writeDB($DB_PATH);
        
        if(my $ToDir = $In::Opt{"JsonReport"}) {
            createJsonReport($ToDir);
        }
        else {
            createTimeline();
        }
    }
    
    if($In::Opt{"GlobalIndex"}) {
        createGlobalIndex();
    }
    
    if(my $ToDir = $In::Opt{"Deploy"})
    {
        printMsg("INFO", "Deploy to $ToDir");
        $ToDir = abs_path($ToDir);
        
        if(not -d $ToDir) {
            mkpath($ToDir);
        }
        
        if($TARGET_LIB)
        {
            # clear deploy directory
            foreach my $Dir (@Reports) {
                rmtree($ToDir."/".$Dir."/".$TARGET_LIB);
            }
            
            # copy reports
            foreach my $Dir (@Reports, "db")
            {
                if(-d $Dir."/".$TARGET_LIB)
                {
                    printMsg("INFO", "Copy $Dir/$TARGET_LIB");
                    mkpath($ToDir."/".$Dir);
                    system("cp -fr \"$Dir/$TARGET_LIB\" \"$ToDir/$Dir/\"");
                }
            }
            printMsg("INFO", "Copy css");
            system("cp -fr css \"$ToDir/\"");
        }
        else
        {
            # clear deploy directory
            foreach my $Dir (@Reports) {
                rmtree($ToDir."/".$Dir);
            }
            
            # copy reports
            foreach my $Dir (@Reports, "db")
            {
                if(-d $Dir)
                {
                    printMsg("INFO", "Copy $Dir");
                    system("cp -fr \"$Dir\" \"$ToDir/\"");
                }
            }
            printMsg("INFO", "Copy css");
            system("cp -fr css \"$ToDir/\"");
        }
    }
}

scenario();
