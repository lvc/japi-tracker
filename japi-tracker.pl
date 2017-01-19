#!/usr/bin/perl
##################################################################
# Java API Tracker 1.1
# A tool to visualize API changes timeline of a Java library
#
# Copyright (C) 2015-2017 Andrey Ponomarenko's ABI Laboratory
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
#  Java API Compliance Checker (1.8 or newer)
#  Java API Monitor (1.1 or newer)
#  PkgDiff (1.6.4 or newer)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License or the GNU Lesser
# General Public License as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# and the GNU Lesser General Public License along with this program.
# If not, see <http://www.gnu.org/licenses/>.
##################################################################
use Getopt::Long;
Getopt::Long::Configure ("posix_default", "no_ignore_case", "permute");
use File::Path qw(mkpath rmtree);
use File::Temp qw(tempdir);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path cwd);
use Data::Dumper;
use Digest::MD5 qw(md5_hex);

my $TOOL_VERSION = "1.1";
my $DB_NAME = "Tracker.data";
my $TMP_DIR = tempdir(CLEANUP=>1);

# Internal modules
my $MODULES_DIR = get_Modules();
push(@INC, dirname($MODULES_DIR));

my $JAPICC = "japi-compliance-checker";
my $JAPICC_VERSION = "1.8";

my $PKGDIFF = "pkgdiff";
my $PKGDIFF_VERSION = "1.6.4";

my ($Help, $DumpVersion, $Build, $Rebuild, $DisableCache,
$TargetVersion, $TargetElement, $Clear, $GlobalIndex, $Deploy, $Debug);

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

my $HomePage = "http://abi-laboratory.pro/";

my $ShortUsage = "API Tracker $TOOL_VERSION
A tool to visualize API changes timeline of a Java library
Copyright (C) 2017 Andrey Ponomarenko's ABI Laboratory
License: GPLv2.0+ or LGPLv2.1+

Usage: $CmdName [options] [profile]
Example:
  $CmdName -build profile.json

More info: $CmdName --help\n";

if($#ARGV==-1)
{
    printMsg("INFO", $ShortUsage);
    exit(0);
}

GetOptions("h|help!" => \$Help,
  "dumpversion!" => \$DumpVersion,
# general options
  "build!" => \$Build,
  "rebuild!" => \$Rebuild,
# internal options
  "v=s" => \$TargetVersion,
  "t|target=s" => \$TargetElement,
  "clear!" => \$Clear,
  "global-index!" => \$GlobalIndex,
  "disable-cache!" => \$DisableCache,
  "deploy=s" => \$Deploy,
  "debug" => \$Debug
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
  modify it under the terms of the GPLv2.0+ or LGPLv2.1+.

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
  
  -clear
      Remove all reports.
  
  -global-index
      Create list of all tested libraries.
  
  -disable-cache
      Enable this option if you've changed filter of checked
      symbols in the library (skipped classes, annotations, etc.).
  
  -deploy DIR
      Copy all reports and css to DIR.
  
  -debug
      Enable debug messages.
";

my $Profile;
my $DB;
my $TARGET_LIB;
my $DB_PATH = undef;

# Regenerate reports
my $ArchivesReport = 0;

# Report style
my $LinkClass = " class='num'";
my $LinkNew = " new";
my $LinkRemoved = " removed";

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
    my $Path = $MODULES_DIR."/Internals/$Name.pm";
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    require $Path;
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
        
        if($Info=~/\"Versions\"/)
        {
            my $Pos = 0;
            
            while($Info=~s/(\"Versions\"\s*:\s*\[\s*)(\{\s*(.|\n)+?\s*\})\s*,?\s*/$1/)
            {
                my $VInfo = readProfile($2);
                if(my $VNum = $VInfo->{"Number"})
                {
                    $VInfo->{"Pos"} = $Pos++;
                    $Res{"Versions"}{$VNum} = $VInfo;
                }
                else {
                    printMsg("ERROR", "version number is missed in the profile");
                }
            }
        }
        
        # arrays
        while($Info=~s/\"(\w+)\"\s*:\s*\[\s*(.*?)\s*\]\s*(\,|\Z)//)
        {
            my ($K, $A) = ($1, $2);
            
            if($K eq "Versions") {
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
            
            if($K eq "Versions") {
                next;
            }
            
            $V=~s/\A[\"\']//;
            $V=~s/[\"\']\Z//;
            
            $Res{$K} = $V;
        }
    }
    
    return \%Res;
}

sub skipVersion_T($)
{
    my $V = $_[0];
    
    if(defined $TargetVersion)
    {
        if($V ne $TargetVersion)
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

sub buildData()
{
    my @Versions = getVersionsList();
    
    if($TargetVersion)
    {
        if(not grep {$_ eq $TargetVersion} @Versions)
        {
            printMsg("ERROR", "unknown version number \'$TargetVersion\'");
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
    
    if($Rebuild and not $TargetElement and $TargetVersion)
    { # rebuild previous API dump
        my $PV = undef;
        
        foreach my $V (reverse(@Versions))
        {
            if($V eq $TargetVersion)
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
    
    if(defined $TargetElement
    and $TargetElement eq "graph")
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
    
    my $Tics = 5;
    if(defined $Profile->{"GraphXTics"}) {
        $Tics = $Profile->{"GraphXTics"};
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
        
        if(defined $Profile->{"GraphShortXTics"})
        {
            if($V=~tr!\.!!>=2) {
                $V_S = getMajor($V);
            }
        }
        
        $V_S=~s/\-(alpha|beta|rc)\d*\Z//g;
        
        $Content .= $_."  ".$Val;
        
        if($_==0 or $_==$#Vs
        or $_==int($#Vs/2))
        {
            $Content .= "  ".$V_S;
        }
        elsif($Tics==5 and ($_==int($#Vs/4)
        or $_==int(3*$#Vs/4)))
        {
            $Content .= "  ".$V_S;
        }
        $Content .= "\n";
        
        $Val_Pre = $Val;
    }
    
    my $Delta = $MaxRange - $MinRange;
    
    if($Delta)
    {
        $MinRange -= int($Delta*5/100);
        $MaxRange += int($Delta*5/100);
    }
    else
    {
        $MinRange -= 5;
        $MaxRange += 5;
    }
    
    
    my $Data = $TMP_DIR."/graph.data";
    
    writeFile($Data, $Content);
    
    my $Title = ""; # Timeline of API changes
    
    my $GraphPath = "graph/$TARGET_LIB/graph.png";
    mkpath(getDirname($GraphPath));
    
    my $Cmd = "gnuplot -e \"set title \'$Title\';";
    $Cmd .= "set xlabel '".showTitle()." version';";
    $Cmd .= "set ylabel 'API symbols';";
    $Cmd .= "set xrange [0:".$#Vs."];";
    $Cmd .= "set yrange [$MinRange:$MaxRange];";
    $Cmd .= "set terminal png size 400,300;";
    $Cmd .= "set output \'$GraphPath\';";
    $Cmd .= "set nokey;";
    $Cmd .= "set xtics font 'Times, 12';";
    $Cmd .= "set ytics font 'Times, 12';";
    $Cmd .= "set xlabel font 'Times, 12';";
    $Cmd .= "set ylabel font 'Times, 12';";
    $Cmd .= "set style line 1 linecolor rgbcolor 'red' linewidth 2;";
    $Cmd .= "set style increment user;";
    $Cmd .= "plot \'$Data\' using 2:xticlabels(3) with lines\"";
    
    system($Cmd);
    unlink($Data);
}

sub findArchives($)
{
    my $Dir = $_[0];
    
    my @Files = findFiles($Dir, "f", ".*\\.jar");
    
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

sub getSover($)
{
    my $Name = $_[0];
    
    my ($Pre, $Post) = (undef, undef);
    
    if($Name=~/\.so\.([\w\.\-]+)/) {
        $Post = $1;
    }
    
    if($Name=~/(\d+[\d\.]*\-[\w\.\-]*)\.so(\.|\Z)/)
    { # libMagickCore6-Q16.so.1
        $Pre = $1;
    }
    elsif($Name=~/\-([a-zA-Z]?\d[\w\.\-]*)\.so(\.|\Z)/)
    { # libMagickCore-6.Q16.so.1
      # libMagickCore-Q16.so.7
        $Pre = $1;
    }
    elsif(not defined $Post and $Name=~/([\d\.])\.so(\.|\Z)/) {
        $Pre = $1;
    }
    
    my @V = ();
    if(defined $Pre) {
        push(@V, $Pre);
    }
    if(defined $Post) {
        push(@V, $Post);
    }
    
    if(@V) {
        return join(".", @V);
    }
    
    return undef;
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
        if(defined $Profile->{"SnapshotVer"}
        and $V eq $Profile->{"SnapshotVer"})
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
    if(my $SnapshotVer = $Profile->{"SnapshotVer"}) {
        return getTimeF($Profile->{"Versions"}{$SnapshotVer}{"Source"});
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
    
    if(not $Rebuild)
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
    
    $Content = composeHTML_Head($Title, $Keywords, $Desc, getTop("changelog"), "changelog.css", "")."\n<body>\n$Content\n</body>\n</html>\n";
    
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
    
    if(defined $TargetElement)
    {
        if($Elem ne $TargetElement)
        {
            return 0;
        }
    }
    
    return 1;
}

sub detectDate($)
{
    my $V = $_[0];
    
    if(not $Rebuild)
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
        
        my $Zip = ($Source=~/\.(zip|jar)\Z/i);
        
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
    
    if(defined $Date)
    {
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
    elsif($Path=~/\.(zip|jar)\Z/i) {
        $Cmd = "unzip -l $Path";
    }
    
    if($Cmd)
    {
        my @Res = split(/\n/, `$Cmd 2>/dev/null`);
        return @Res;
    }
    
    return ();
}

sub createAPIDump($)
{
    my $V = $_[0];
    
    if(not $Rebuild)
    {
        if(defined $DB->{"APIDump"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"APIDump"}{$V}); # empty cache
    
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
        return;
    }
    
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
        my $Name = getFilename($Ar);
        
        my $Module = getArchiveName(getFilename($Ar), "Short");
        if(not $Module) {
            $Module = getFilename($Ar);
        }
        
        my $Cmd = $JAPICC." -l \"$Module\" -dump \"".$Ar."\" -dump-path \"".$APIDump."\" -vnum \"$V\"";
        
        if(not $Profile->{"PrivateAPI"})
        { # set "PrivateAPI":1 in the profile to check all symbols
            
        }
        
        if($Debug) {
            printMsg("DEBUG", "executing $Cmd");
        }
        
        my $Log = `$Cmd`; # execute
        
        if(-f $APIDump)
        {
            $DB->{"APIDump"}{$V}{$Md5}{"Path"} = $APIDump;
            $DB->{"APIDump"}{$V}{$Md5}{"Archive"} = $RPath;
            
            my $API = eval(readFile($APIDump));
            $DB->{"APIDump"}{$V}{$Md5}{"Lang"} = $API->{"Language"};
            
            my $TotalSymbols = countSymbols($DB->{"APIDump"}{$V}{$Md5});
            $DB->{"APIDump"}{$V}{$Md5}{"TotalSymbols"} = $TotalSymbols;
            
            my @Meta = ();
            
            push(@Meta, "\"Archive\": \"".$RPath."\"");
            push(@Meta, "\"Lang\": \"".$API->{"Language"}."\"");
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
}

sub countSymbolsF($$)
{
    my ($Dump, $V) = @_;
    
    if(defined $Dump->{"TotalSymbolsFiltered"})
    {
        if(not defined $DisableCache) {
            return $Dump->{"TotalSymbolsFiltered"};
        }
    }
    
    my $AccOpts = getJAPICC_Options($V);
    
    if($AccOpts=~/list|skip|keep/
    and not $Profile->{"Versions"}{$V}{"WithoutAnnotations"})
    {
        my $Path = $Dump->{"Path"};
        printMsg("INFO", "Counting symbols in the API dump for \'".getFilename($Dump->{"Archive"})."\'");
        
        my $Cmd_C = "$JAPICC -count-methods \"$Path\" $AccOpts";
        
        if($Debug) {
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
    
    if($Debug) {
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
    
    $Name=~s/\.jar\Z//g;
    
    if(my $Suffix = $Profile->{"ArchiveSuffix"}) {
        $Name=~s/\Q$Suffix\E\Z//g;
    }
    
    if($T=~/Shortest/)
    { # httpcore5-5.0-alpha1.jar
        $Name=~s/\A([a-z]{3,})\d+(\-)/$1$2/ig;
    }
    
    if($T=~/Short/)
    {
        if(not $Name=~s/\A(.+?)[\-\_][v\d\.\-\_]+(|[\-\_\.](final|release|snapshot|RC\d*|beta\d*|alpha\d*))\Z/$1/ig)
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
    
    if(not $Rebuild)
    {
        if(defined $DB->{"APIReport"}{$V1}{$V2})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"APIReport"}{$V1}{$V2}); # empty cache
    
    printMsg("INFO", "Creating archives API report between $V1 and $V2");
    
    my $Cols = 6;
    
    if($Profile->{"CompatRate"} eq "Off") {
        $Cols-=2;
    }
    
    if(not $Profile->{"ShowTotalProblems"}) {
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
    
    if(not defined $DB->{"APIDump"}{$V1}) {
        createAPIDump($V1);
    }
    if(not defined $DB->{"APIDump"}{$V2}) {
        createAPIDump($V2);
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
        if($Rebuild)
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
    
    $Report .= "<table class='summary'>\n";
    $Report .= "<tr>";
    $Report .= "<th rowspan='2'>Archive</th>\n";
    if($Profile->{"CompatRate"} ne "Off") {
        $Report .= "<th colspan='2'>Backward<br/>Compatibility</th>\n";
    }
    $Report .= "<th rowspan='2'>Added<br/>Methods</th>\n";
    $Report .= "<th rowspan='2'>Removed<br/>Methods</th>\n";
    if($Profile->{"ShowTotalProblems"}) {
        $Report .= "<th colspan='2'>Total Changes</th>\n";
    }
    $Report .= "</tr>\n";
    
    if($Profile->{"CompatRate"} ne "Off" or $Profile->{"ShowTotalProblems"})
    {
        $Report .= "<tr>";
        
        if($Profile->{"CompatRate"} ne "Off")
        {
            $Report .= "<th title='Binary compatibility'>BC</th>\n";
            $Report .= "<th title='Source compatibility'>SC</th>\n";
        }
        
        if($Profile->{"ShowTotalProblems"})
        {
            $Report .= "<th title='Binary compatibility'>BC</th>\n";
            $Report .= "<th title='Source compatibility'>SC</th>\n";
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
        
        $Name=~s/\A(share|dist|jars)\///;
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
        
        $Name=~s/\A(share|dist|jars)\///;
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
                        else {
                            $CClass = "incompatible";
                        }
                    }
                    $Report .= "<td class=\'$CClass\'>";
                    if(not $Changed and $Profile->{"HideEmpty"}) {
                        $Report .= formatNum($BC_D)."%";
                    }
                    else {
                        $Report .= "<a href='../../../../".$APIReport_D->{"Path"}."'>".formatNum($BC_D)."%</a>";
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
                        else {
                            $CClass_Source = "incompatible";
                        }
                    }
                    
                    $Report .= "<td class=\'$CClass_Source\'>";
                    if(not $Changed and $Profile->{"HideEmpty"}) {
                        $Report .= formatNum($BC_D_Source)."%";
                    }
                    else {
                        $Report .= "<a href='../../../../".$APIReport_D->{"Source_ReportPath"}."'>".formatNum($BC_D_Source)."%</a>";
                    }
                    $Report .= "</td>\n";
                }
                
                if($AddedSymbols) {
                    $Report .= "<td class='added'><a$LinkClass href='../../../../".$APIReport_D->{"Path"}."#Added'>".$AddedSymbols.$LinkNew."</a></td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
                
                if($RemovedSymbols) {
                    $Report .= "<td class='removed'><a$LinkClass href='../../../../".$APIReport_D->{"Path"}."#Removed'>".$RemovedSymbols.$LinkRemoved."</a></td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
                
                if($Profile->{"ShowTotalProblems"})
                {
                    if($TotalProblems) {
                        $Report .= "<td class=\'warning\'><a$LinkClass href='../../../../".$APIReport_D->{"Path"}."'>$TotalProblems</a></td>\n";
                    }
                    else {
                        $Report .= "<td class='ok'>0</td>\n";
                    }
                    
                    if($TotalProblems_Source) {
                        $Report .= "<td class=\'warning\'><a$LinkClass href='../../../../".$APIReport_D->{"Source_ReportPath"}."'>$TotalProblems_Source</a></td>\n";
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
    
    if(not $Analyzed)
    {
        rmtree($Dir);
        return;
    }
    
    $Report .= getSign("Other");
    
    my $Title = showTitle().": Archives API report between $V1 and $V2 versions";
    my $Keywords = showTitle().", API, changes, compatibility, report";
    my $Desc = "API changes/compatibility report between $V1 and $V2 versions of the $TARGET_LIB";
    
    $Report = composeHTML_Head($Title, $Keywords, $Desc, getTop("archives_report"), "report.css", "")."\n<body>\n$Report\n</body>\n</html>\n";
    
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

sub formatNum($)
{
    my $Num = $_[0];
    
    if($Num=~/\A(\d+\.\d\d)/) {
        return $1;
    }
    
    return $Num
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
    
    if(not $Rebuild)
    {
        if(defined $DB->{"APIReport_D"}{$V1}{$V2}
        and defined $DB->{"APIReport_D"}{$V1}{$V2}{$Md5})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"APIReport_D"}{$V1}{$V2}{$Md5}); # empty cache
    
    printMsg("INFO", "Creating JAPICC report for $Ar1 ($V1) and $Ar2 ($V2)");
    
    my $TmpDir = $TMP_DIR."/apicc/";
    mkpath($TmpDir);
    
    my $Dump1 = $DB->{"APIDump"}{$V1}{getMd5($Ar1)};
    my $Dump2 = $DB->{"APIDump"}{$V2}{getMd5($Ar2)};
    
    my $Dump1_Meta = readProfile(readFile(getDirname($Dump1->{"Path"})."/meta.json"));
    my $Dump2_Meta = readProfile(readFile(getDirname($Dump2->{"Path"})."/meta.json"));
    
    my $Dir = "compat_report/$TARGET_LIB/$V1/$V2/$Md5";
    my $BinReport = $Dir."/bin_compat_report.html";
    my $SrcReport = $Dir."/src_compat_report.html";
    
    my $Module = getArchiveName(getFilename($Ar1), "Short");
    if(not $Module) {
        $Module = getFilename($Ar1);
    }
    
    my $Cmd = $JAPICC." -l \"$Module\" -binary -source -old \"".$Dump1->{"Path"}."\" -new \"".$Dump2->{"Path"}."\" -bin-report-path \"$BinReport\" -src-report-path \"$SrcReport\"";
    
    if(my $AccOpts = getJAPICC_Options($V2)) {
        $Cmd .= $AccOpts;
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
    
    if($Debug) {
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
    
    my $Line = readLineNum($SrcReport, 0);
    if($Line=~/affected:(.+?);/) {
        $Affected_Source = $1;
    }
    while($Line=~s/\w+_problems_\w+:(.+?);//) {
        $Total_Source += $2;
    }
    
    my %Meta = ();
    
    $Meta{"Affected"} = $Affected;
    $Meta{"Added"} = $Added;
    $Meta{"Removed"} = $Removed;
    $Meta{"TotalProblems"} = $Total;
    $Meta{"Path"} = $BinReport;
    
    $Meta{"Source_Affected"} = $Affected_Source;
    $Meta{"Source_TotalProblems"} = $Total_Source;
    $Meta{"Source_ReportPath"} = $SrcReport;
    
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
    my $Opt = "";
    
    if(my $SkipPackages = $Profile->{"SkipPackages"}) {
        $Opt .= " -skip-packages \"$SkipPackages\"";
    }
    
    if(my $SkipClasses = $Profile->{"SkipClasses"}) {
        $Opt .= " -skip-classes \"$SkipClasses\"";
    }
    
    if(my $SkipInternalPackages = $Profile->{"SkipInternalPackages"}) {
        $Opt .= " -skip-internal-packages \"$SkipInternalPackages\"";
    }
    
    if(my $SkipInternalTypes = $Profile->{"SkipInternalTypes"}) {
        $Opt .= " -skip-internal-types \"$SkipInternalTypes\"";
    }
    
    if(not $Profile->{"Versions"}{$V}{"WithoutAnnotations"})
    {
        if(my $AnnotationList = $Profile->{"AnnotationList"}) {
            $Opt .= " -annotations-list \"$AnnotationList\"";
        }
        
        if(my $SkipAnnotationList = $Profile->{"SkipAnnotationList"}) {
            $Opt .= " -skip-annotations-list \"$SkipAnnotationList\"";
        }
    }
    
    return $Opt;
}

sub createPkgdiff($$)
{
    my ($V1, $V2) = @_;
    
    if($Profile->{"Versions"}{$V2}{"PkgDiff"} ne "On"
    and not (defined $TargetVersion and defined $TargetElement)) {
        return 0;
    }
    
    if(not $Rebuild)
    {
        if(defined $DB->{"PackageDiff"}{$V1}{$V2}) {
            return 0;
        }
    }
    
    delete($DB->{"PackageDiff"}{$V1}{$V2}); # empty cache
    
    printMsg("INFO", "Creating package diff for $V1 and $V2");
    
    my $Source1 = $Profile->{"Versions"}{$V1}{"Source"};
    my $Source2 = $Profile->{"Versions"}{$V2}{"Source"};
    
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

sub getTop($)
{
    my $Page = $_[0];
    
    my $Rel = "";
    
    if($Page=~/\A(changelog)\Z/) {
        $Rel = "../../..";
    }
    elsif($Page=~/\A(archives_report)\Z/) {
        $Rel = "../../../..";
    }
    elsif($Page=~/\A(timeline)\Z/) {
        $Rel = "../..";
    }
    elsif($Page=~/\A(global_index)\Z/) {
        $Rel = ".";
    }
    
    return $Rel;
}

sub getHead($)
{
    my $Sel = $_[0];
    
    my $UrlPr = getTop($Sel);
    
    my $ReportHeader = "API<br/>Tracker";
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

sub getS($)
{
    if($_[0]>1) {
        return "s";
    }
    
    return "";
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

sub createTimeline()
{
    $DB->{"Updated"} = time;
    
    writeCss();
    
    my $Title = showTitle().": API changes review";
    my $Desc = "API compatibility analysis reports for ".showTitle();
    my $Content = composeHTML_Head($Title, $TARGET_LIB.", API, compatibility, report", $Desc, getTop("timeline"), "report.css", "");
    $Content .= "<body>\n";
    
    my @Versions = getVersionsList();
    
    my $CompatRate = "On";
    my $Changelog = "Off";
    my $PkgDiff = "Off";
    
    if($Profile->{"CompatRate"} eq "Off") {
        $CompatRate = "Off";
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
    
    if(not $Profile->{"ShowTotalProblems"}) {
        $Cols-=2;
    }
    
    if($Changelog eq "Off") {
        $Cols-=1;
    }
    
    if($PkgDiff eq "Off") {
        $Cols-=1;
    }
    
    $Content .= getHead("timeline");
    
    my $ContentHeader = "API changes review";
    if(defined $Profile->{"ContentHeader"}) {
        $ContentHeader = $Profile->{"ContentHeader"};
    }
    
    $Content .= "<h1>".$ContentHeader."</h1>\n";
    $Content .= "<br/>";
    $Content .= "<br/>";
    
    my $GraphPath = "graph/$TARGET_LIB/graph.png";
    
    if(-f $GraphPath) {
        $Content .= "<table cellpadding='0' cellspacing='0'><tr><td valign='top'>\n";
    }
    
    $Content .= "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>\n";
    $Content .= "<th rowspan='2'>Version</th>\n";
    $Content .= "<th rowspan='2'>Date</th>\n";
    
    if($Changelog ne "Off") {
        $Content .= "<th rowspan='2'>Change<br/>Log</th>\n";
    }
    
    if($CompatRate ne "Off") {
        $Content .= "<th colspan='2'>Backward<br/>Compatibility</th>\n";
    }
    
    $Content .= "<th rowspan='2'>Added<br/>Methods</th>\n";
    $Content .= "<th rowspan='2'>Removed<br/>Methods</th>\n";
    if($Profile->{"ShowTotalProblems"}) {
        $Content .= "<th colspan='2'>Total Changes</th>\n";
    }
    
    if($PkgDiff ne "Off") {
        $Content .= "<th rowspan='2'>Package<br/>Diff</th>\n";
    }
    
    $Content .= "</tr>\n";
    
    if($CompatRate ne "Off" or $Profile->{"ShowTotalProblems"})
    {
        $Content .= "<tr>\n";
        
        if($CompatRate ne "Off")
        {
            $Content .= "<th title='Binary compatibility'>BC</th>\n";
            $Content .= "<th title='Source compatibility'>SC</th>\n";
        }
        
        if($Profile->{"ShowTotalProblems"})
        {
            $Content .= "<th title='Binary compatibility'>BC</th>\n";
            $Content .= "<th title='Source compatibility'>SC</th>\n";
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
        my $Sover = "N/A";
        
        if(defined $DB->{"Date"} and defined $DB->{"Date"}{$V}) {
            $Date = $DB->{"Date"}{$V};
        }
        
        if(defined $DB->{"Sover"} and defined $DB->{"Sover"}{$V}) {
            $Sover = $DB->{"Sover"}{$V};
        }
        
        my $Anchor = $V;
        if($V ne "current") {
            $Anchor = "v".$Anchor;
        }
        
        $Content .= "<tr id='".$Anchor."'>";
        
        $Content .= "<td title='".getFilename($Profile->{"Versions"}{$V}{"Source"})."'>".$V."</td>\n";
        $Content .= "<td>".showDate($V, $Date)."</td>\n";
        
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
                    push(@Note, "<span class='added'>added $ArchivesAdded archive".getS($ArchivesAdded)."</span>");
                }
                
                if($ArchivesRemoved) {
                    push(@Note, "<span class='incompatible'>removed $ArchivesRemoved archive".getS($ArchivesRemoved)."</span>");
                }
                
                my $CClass = "ok";
                if($BC ne "100")
                {
                    if(int($BC)>=90) {
                        $CClass = "warning";
                    }
                    else {
                        $CClass = "incompatible";
                    }
                }
                elsif($TotalProblems) {
                    $CClass = "warning";
                }
                
                my $BC_Summary = "<a href='../../".$APIReport->{"Path"}."'>$BC%</a>";
                
                my $CClass_Source = "ok";
                if($BC_Source ne "100")
                {
                    if(int($BC_Source)>=90) {
                        $CClass_Source = "warning";
                    }
                    else {
                        $CClass_Source = "incompatible";
                    }
                }
                elsif($TotalProblems_Source) {
                    $CClass_Source = "warning";
                }
                
                my $BC_Summary_Source = "<a href='../../".$APIReport->{"Path"}."'>$BC_Source%</a>";
                
                if(@Note)
                {
                    $BC_Summary .= "<br/>\n";
                    $BC_Summary .= "<br/>\n";
                    $BC_Summary .= "<span class='note'>".join("<br/>", @Note)."</span>\n";
                }
                
                if($BC_Summary eq $BC_Summary_Source) {
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
                $Content .= "<td class='added'><a$LinkClass href='../../".$APIReport->{"Path"}."'>".$Added.$LinkNew."</a></td>\n";
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
                $Content .= "<td class='removed'><a$LinkClass href='../../".$APIReport->{"Path"}."'>".$Removed.$LinkRemoved."</a></td>\n";
            }
            else {
                $Content .= "<td class='ok'>0</td>\n";
            }
        }
        else {
            $Content .= "<td>N/A</td>\n";
        }
        
        if($Profile->{"ShowTotalProblems"})
        {
            if(defined $APIReport)
            {
                if(my $TotalProblems = $APIReport->{"TotalProblems"}) {
                    $Content .= "<td class=\'warning\'><a$LinkClass href='../../".$APIReport->{"Path"}."'>$TotalProblems</a></td>\n";
                }
                else {
                    $Content .= "<td class='ok'>0</td>\n";
                }
                
                if(my $TotalProblems_Source = $APIReport->{"TotalProblems_Source"}) {
                    $Content .= "<td class=\'warning\'><a$LinkClass href='../../".$APIReport->{"Source_ReportPath"}."'>$TotalProblems_Source</a></td>\n";
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
    
    my $Date = localtime($DB->{"Updated"});
    $Date=~s/(\d\d:\d\d):\d\d/$1/;
    
    $Content .= "Last updated on ".$Date.".";
    
    $Content .= "<br/>";
    $Content .= "<br/>";
    $Content .= "Generated by <a href='https://github.com/lvc/japi-tracker'>Java API Tracker</a> and <a href='https://github.com/lvc/japi-compliance-checker'>JAPICC</a> tools.";
    
    if(-f $GraphPath)
    {
        $Content .= "</td><td width='100%' valign='top' align='left' style='padding-left:4em;'>\n";
        $Content .= "<img src=\'../../$GraphPath\' alt='Timeline of API changes' />\n";
        $Content .= "</td>\n";
        $Content .=  "</tr>\n";
        $Content .= "</table>\n";
    }
    
    $Content .= getSign("Home");
    
    $Content .= "</body></html>";
    
    my $Output = "timeline/".$TARGET_LIB."/index.html";
    writeFile($Output, $Content);
    printMsg("INFO", "The index has been generated to: $Output");
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
    
    my $Title = "Maintained Java libraries";
    my $Desc = "List of maintained libraries";
    my $Content = composeHTML_Head($Title, "", $Desc, getTop("global_index"), "report.css", "");
    $Content .= "<body>\n";
    
    $Content .= getHead("global_index");
    
    $Content .= "<h1>Maintained Java libraries (".($#Libs+1).")</h1>\n";
    $Content .= "<br/>";
    $Content .= "<br/>";
    
    $Content .= "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>\n";
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
            my $DB = eval(readFile("db/$L/$DB_NAME"));
            
            if(defined $DB->{"Title"}) {
                $Title = $DB->{"Title"};
            }
        }
        
        $LibAttr{$L}{"Title"} = $Title;
        
        # $LibAttr{$L}{"Maintainer"} = $M;
        # $LibAttr{$L}{"MaintainerUrl"} = $MUrl;
    }
    
    foreach my $L (sort {lc($LibAttr{$a}{"Title"}) cmp lc($LibAttr{$b}{"Title"})} @Libs)
    {
        $Content .= "<tr>\n";
        $Content .= "<td class='sl'>".$LibAttr{$L}{"Title"}."</td>\n";
        $Content .= "<td><a href='timeline/$L/index.html'>review</a></td>\n";
        
        # my $M = $LibAttr{$L}{"Maintainer"};
        # if(my $MUrl = $LibAttr{$L}{"MaintainerUrl"}) {
        #     $M = "<a href='".$MUrl."'>$M</a>";
        # }
        # $Content .= "<td>$M</td>\n";
        
        $Content .= "</tr>\n";
    }
    
    $Content .= "</table>";
    
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
                
                my $Meta = readProfile(readFile($Dir."/meta.json"));
                $Info{"Archive"} = $Meta->{"Archive"};
                $Info{"Lang"} = $Meta->{"Lang"};
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
                if(not defined $DB->{"APIReport_D"}{$V1}{$V2}{$Md5})
                {
                    my %Info = ();
                    my $Dir = $APIReports_D."/".$V1."/".$V2."/".$Md5;
                    
                    $Info{"Path"} = $Dir."/bin_compat_report.html";
                    
                    my $Meta = readProfile(readFile($Dir."/meta.json"));
                    $Info{"Affected"} = $Meta->{"Affected"};
                    $Info{"Added"} = $Meta->{"Added"};
                    $Info{"Removed"} = $Meta->{"Removed"};
                    $Info{"TotalProblems"} = $Meta->{"TotalProblems"};
                    
                    $Info{"Source_Affected"} = $Meta->{"Source_Affected"};
                    $Info{"Source_TotalProblems"} = $Meta->{"Source_TotalProblems"};
                    $Info{"Source_ReportPath"} = $Meta->{"Source_ReportPath"};
                    
                    $Info{"Archive1"} = $Meta->{"Archive1"};
                    $Info{"Archive2"} = $Meta->{"Archive2"};
                    
                    $DB->{"APIReport_D"}{$V1}{$V2}{$Md5} = \%Info;
                }
            }
        }
    }
    
    my $APIReports = "archives_report/$TARGET_LIB";
    foreach my $V1 (listDir($APIReports))
    {
        foreach my $V2 (listDir($APIReports."/".$V1))
        {
            if(not defined $DB->{"APIReport"}{$V1}{$V2})
            {
                my %Info = ();
                my $Dir = $APIReports."/".$V1."/".$V2;
                
                $Info{"Path"} = $Dir."/report.html";
                
                my $Meta = readProfile(readFile($Dir."/meta.json"));
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
        }
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
    
    if($Rebuild) {
        $Build = 1;
    }
    
    if($TargetElement)
    {
        if($TargetElement!~/\A(date|dates|changelog|apidump|apireport|pkgdiff|packagediff|graph|archivesreport)\Z/)
        {
            exitStatus("Error", "the value of -target option should be one of the following: date, changelog, apidump, apireport, pkgdiff.");
        }
    }
    
    if($TargetElement eq "archivesreport")
    {
        $TargetElement = "apireport";
        $ArchivesReport = 1;
    }
    
    if($DumpVersion)
    {
        printMsg("INFO", $TOOL_VERSION);
        exit(0);
    }
    
    if($Help)
    {
        printMsg("INFO", $HelpMessage);
        exit(0);
    }
    
    if(-d "objects_report") {
        exitStatus("Error", "Can't execute inside the ABI tracker home directory");
    }
    
    loadModule("Basic");
    
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
    
    my @Reports = ("timeline", "package_diff", "changelog", "api_dump", "archives_report", "compat_report", "graph");
    
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
        
        if($Clear)
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
        
        if($Build)
        {
            writeDB($DB_PATH);
            buildData();
        }
        
        writeDB($DB_PATH);
        
        createTimeline();
    }
    
    if($GlobalIndex) {
        createGlobalIndex();
    }
    
    if($Deploy)
    {
        printMsg("INFO", "Deploy to $Deploy");
        $Deploy = abs_path($Deploy);
        
        if(not -d $Deploy) {
            mkpath($Deploy);
        }
        
        if($TARGET_LIB)
        {
            # clear deploy directory
            foreach my $Dir (@Reports) {
                rmtree($Deploy."/".$Dir."/".$TARGET_LIB);
            }
            
            # copy reports
            foreach my $Dir (@Reports, "db")
            {
                if(-d $Dir."/".$TARGET_LIB)
                {
                    printMsg("INFO", "Copy $Dir/$TARGET_LIB");
                    mkpath($Deploy."/".$Dir);
                    system("cp -fr \"$Dir/$TARGET_LIB\" \"$Deploy/$Dir/\"");
                }
            }
            printMsg("INFO", "Copy css");
            system("cp -fr css \"$Deploy/\"");
        }
        else
        {
            # clear deploy directory
            foreach my $Dir (@Reports) {
                rmtree($Deploy."/".$Dir);
            }
            
            # copy reports
            foreach my $Dir (@Reports, "db")
            {
                if(-d $Dir)
                {
                    printMsg("INFO", "Copy $Dir");
                    system("cp -fr \"$Dir\" \"$Deploy/\"");
                }
            }
            printMsg("INFO", "Copy css");
            system("cp -fr css \"$Deploy/\"");
        }
    }
}

scenario();
