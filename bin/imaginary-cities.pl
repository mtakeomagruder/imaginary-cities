#!/usr/bin/perl
####################################################################################################################################
# Map transformations for Imaginary Cities Project
####################################################################################################################################

####################################################################################################################################
# Perl includes
####################################################################################################################################
use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);
use English '-no_match_vars';

# Convert die to confess to capture the stack trace
$SIG{__DIE__} = sub { Carp::confess @_ };

use Cwd qw(abs_path);
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(dirname);
use File::Path qw(remove_tree);
use Getopt::Long qw(GetOptions);
use Imager;
use Pod::Usage qw(pod2usage);
use Time::JulianDay qw(julian_day);
use YAML qw(LoadFile);

####################################################################################################################################
# Constants
####################################################################################################################################
use constant                                                        true  => 1;
use constant                                                        false => 0;

####################################################################################################################################
# Usage
####################################################################################################################################

=head1 NAME

imaginary-cities.pl - Imaginary Cities Image Engine

=head1 SYNOPSIS

imaginary-cities.pl [options]

Test Options:
   --wipe-image-dst     wipe the image destination directory

 General Options:
   --help               display usage and exit
   --version            display version and exit
=cut

####################################################################################################################################
# Command line parameters
####################################################################################################################################
my $bHelp = false;
my $bVersion = false;
my $bWipeImageDestination = false;
my @stryDate;

GetOptions(
    'help' => \$bHelp,
    'version' => \$bVersion,
    'wipe-image-dst' => \$bWipeImageDestination,
    'date=s@' => \@stryDate,
) or pod2usage(2);

####################################################################################################################################
# Project variables paths
####################################################################################################################################
my $strProject = 'Imaginary Cities Image Engine';
my $strProjectVersion = '0.50';
my $strProjectExe = 'imaginary-cities';

my $strBasePath = dirname(dirname(abs_path($0)));
my $strImagePath = "${strBasePath}/image";
my $strImageSrcPath = "${strImagePath}/src";
my $strImageDstPath = "${strImagePath}/dst";

my $strLockFile = "/tmp/${strProjectExe}.lock";
my $strYamlFile = "${strBasePath}/${strProjectExe}.yaml";

####################################################################################################################################
# Display help/version if requested
####################################################################################################################################
if ($bVersion || $bHelp)
{
    syswrite(*STDOUT, "${strProject} v${strProjectVersion}\n");

    if ($bHelp)
    {
        syswrite(*STDOUT, "\n");
        pod2usage();
    }

    exit 0;
}

####################################################################################################################################
# Make sure process is not already running
####################################################################################################################################
sysopen(my $fhLockFile, $strLockFile, O_WRONLY | O_CREAT)
    or confess "unable to open lock file: ${strLockFile}";

flock($fhLockFile, LOCK_EX | LOCK_NB)
    or exit(0);

####################################################################################################################################
# Wipe (if requested) and create the image destination directory
####################################################################################################################################
if ($bWipeImageDestination && -e $strImageDstPath)
{
    remove_tree($strImageDstPath) > 0
        or confess "unable to remove ${strImageDstPath}";
}

# No error here because the directory might already exist and that's OK
mkdir($strImageDstPath, oct('0750'));

####################################################################################################################################
# Parse dates (or supply default)
####################################################################################################################################
my $hDateList;

# If dates were passed on the command line
if (@stryDate > 0)
{
    # Loop through all dates
    foreach my $strDate (@stryDate)
    {
        # Error on obviously bogus dates
        if ($strDate !~ /^[0-9]{8}$/)
        {
            confess "--date=${strDate} does not appear to be a date'";
        }

        $hDateList->{$strDate} = {year => substr($strDate, 0, 4), month => substr($strDate, 4, 2), day => substr($strDate, 6, 2)};
    }
}
# Else use today (GMT)
else
{
    my ($iCurrentSecond, $iCurrentMinute, $iCurrentHour, $iCurrentMonthDay, $iCurrentMonth, $iCurrentYear) = gmtime(time());
    my $hDate = {year => $iCurrentYear + 1900, month => $iCurrentMonth + 1, day => $iCurrentMonthDay};

    $hDateList->{sprintf('%04d%02d%02d', $hDate->{year}, $hDate->{month}, $hDate->{day})} = $hDate;
}

####################################################################################################################################
# Loop through available images
####################################################################################################################################
my $hyImageData = LoadFile($strYamlFile);

foreach my $hImageData (@{$hyImageData->{imageList}})
{
    # Open image
    #-------------------------------------------------------------------------------------------------------------------------------
    my $oBaseImage = Imager->new();

    $oBaseImage->read(file => "${strImageSrcPath}/$hImageData->{fileName}")
        or confess $oBaseImage->errstr;

    # Convert to gray scale
    #-------------------------------------------------------------------------------------------------------------------------------
    $oBaseImage = $oBaseImage->convert(preset => 'grey');

    # Check the crop dimensions
    #-------------------------------------------------------------------------------------------------------------------------------
    $hImageData->{cropWidth} % 8 == 0
        or confess "'$hImageData->{name}' cropWidth must be divisible by 8";

    $hImageData->{cropHeight} % 8 == 0
        or confess "'$hImageData->{name}' cropHeight must be divisible by 8";

    $hImageData->{rectangle} % 8 == 0
        or confess "'$hImageData->{name}' collageWidth must be divisible by 8";

    # Check bounds
    #-------------------------------------------------------------------------------------------------------------------------------
    $hImageData->{cropLeft} + $hImageData->{cropWidth} <= $oBaseImage->getwidth()
        or confess "'$hImageData->{name}' cropLeft + cropWidth must be <= image width";

    $hImageData->{cropTop} + $hImageData->{cropHeight} <= $oBaseImage->getheight()
        or confess "'$hImageData->{name}' cropTop + cropHeight must be <= image height";

    $hImageData->{rectangle} <= $hImageData->{cropWidth}
        or confess "'$hImageData->{name}' collageWidth must be <= cropWidth";

    $hImageData->{rectangle} <= $hImageData->{cropHeight}
        or confess "'$hImageData->{name}' collageWidth must be <= cropHeight";

    # Loop through provided dates
    #-------------------------------------------------------------------------------------------------------------------------------
    foreach my $strDate (sort(keys(%$hDateList)))
    {
        # Get date info
        #---------------------------------------------------------------------------------------------------------------------------
        my $hDate = $hDateList->{$strDate};

        # Calculate permutation
        #---------------------------------------------------------------------------------------------------------------------------
        my $iLoopX = $hImageData->{cropWidth} - $hImageData->{rectangle} + 1;
        my $iLoopY = $hImageData->{cropHeight} - $hImageData->{rectangle} + 1;

        my $iPermutationTotal = ($iLoopX * $iLoopY) / $hImageData->{permutationStep};
        my $iPermutation = julian_day($hDate->{year}, $hDate->{month}, $hDate->{day}) % $iPermutationTotal;

        my $iOffset = (($iLoopX * $iLoopY) / $iPermutationTotal) * $iPermutation;
        my $iOffsetX = $iOffset % $iLoopX;
        my $iOffsetY = int(($iOffset - $iOffsetX) / $iLoopX);

        print "$strDate iLoopX $iLoopX, iLoopY $iLoopY, iPermutation $iPermutation" .
            ", iTotalOffset = " . ($iLoopX * $iLoopY) .
            ", iOffset $iOffset, iOffsetX $iOffsetX, iOffsetY $iOffsetY\n";

        # Crop image
        #---------------------------------------------------------------------------------------------------------------------------
        my $oImage = $oBaseImage->crop(
            left => $hImageData->{cropLeft} + $iOffsetX, top => $hImageData->{cropTop} + $iOffsetY,
            width => $hImageData->{rectangle}, height => $hImageData->{rectangle})
            or confess $oBaseImage->errstr;

        # Scale to output size
        #---------------------------------------------------------------------------------------------------------------------------
        $oImage = $oImage->scale(xpixels => $hyImageData->{outWidth} / 2)
            or confess $oImage->errstr;

        # Apply filters
        #---------------------------------------------------------------------------------------------------------------------------
        foreach my $hFilter (@{$hImageData->{filterList}})
        {
            if ($hFilter->{type} eq 'unsharpmask')
            {
                $oImage = $oImage->filter(type => $hFilter->{type}, stddev => $hFilter->{stddev}, scale => $hFilter->{scale})
                    or confess $oImage->errstr;
            }

            if ($hFilter->{type} eq 'contrast')
            {
                $oImage->filter(type => 'contrast', intensity => $hFilter->{intensity})
                    or confess $oImage->errstr;
            }
        }

        # Output the source file
        #---------------------------------------------------------------------------------------------------------------------------
        $oImage->write(file => "${strImageDstPath}/$hImageData->{name}-${strDate}.jpg", jpegquality => 75)
            or confess $oImage->errstr;

        # Create collage
        #---------------------------------------------------------------------------------------------------------------------------
        my $oCollage = Imager->new(xsize => $hyImageData->{outWidth}, ysize => $hyImageData->{outWidth});

        for (my $iIndex = 0; $iIndex < 4; $iIndex++)
        {
            my $iX = $iIndex == 1 || $iIndex == 2 ? $hyImageData->{outWidth} / 2 : 0;
            my $iY = $iIndex == 2 || $iIndex == 3 ? $hyImageData->{outWidth} / 2 : 0;
            my $strDirection = $iIndex == 1 || $iIndex == 3 ? 'h' : ($iIndex == 2 ? 'v' : undef);

            $oCollage->rubthrough(
                src => (defined($strDirection) ? $oImage->flip(dir => $strDirection) : $oImage), tx => $iX, ty => $iY);
        }

        $oCollage->compose(src => $oCollage->rotate(degrees => 90), opacity => 0.5);

        $oCollage->write(file => "${strImageDstPath}/$hImageData->{name}-collage-${strDate}.tif", tiff_compression => 5)
            or confess $oImage->errstr;
    }
}

####################################################################################################################################
# Remove and close the lock file (ignore any failures)
####################################################################################################################################
unlink($strLockFile);
close($fhLockFile);
