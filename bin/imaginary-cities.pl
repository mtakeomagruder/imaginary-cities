#!/usr/bin/env perl

####################################################################################################################################
# Imaginary Cities Image Engine for Michael Takeo Magruder’s “Imaginary Cities” Project
#
# This software transforms bitmaps from British Library’s “One Million Images from Scanned Books” collection hosted on Flickr
# Commons. The engine is the technical bridge between the digital collection and the artworks. The output is completely
# deterministic based on the inputs, i.e. a specific bitmap on the same day with the equivalent filters, metadata and resolution
# will be identical whenever it is produced. There are random perturbations to the image permutations and filters based on a
# cryptograhic hash generated from inputs that vary each day, but they are constant for any given day.
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
use DBD::Pg;
use Digest::SHA qw(sha1 sha1_hex);
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(basename dirname);
use File::Path qw(make_path remove_tree);
use Getopt::Long qw(GetOptions);
use Imager;
use JSON::PP;
use LWP::UserAgent;
use Pod::Usage qw(pod2usage);
use Time::JulianDay qw(julian_day);
use URI::Escape;
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

 Options:
   --date               generation date(s) (defaults to today)
   --fetch-only         fetch metadata only, do not render
   --image              image to generate (default is all)
   --file-out           output file (image/dst/defaults to [image]-collage-YYYYMMDD)
   --format-out         output file format (jpg/png/tif - defaults to tif)
   --width-out          output width for images (default is YAML setting)

 Test Options:
   --verbose            log debug information
   --wipe-image-dst     wipe the image destination directory

 General Options:
   --help               display usage and exit
   --version            display version and exit
=cut

####################################################################################################################################
# Command line parameters
####################################################################################################################################
my @stryDate;                                                       # Date(s) to render
my $bFetchOnly = false;                                             # Only fetch new data, don't render
my $strFileOut = undef;                                             # Output file name
my $strFormatOut = 'tif';                                           # Output file format
my $bHelp = false;                                                  # Display help
my $strImage = undef;                                               # Image to render
my $bVerbose = false;                                               # Output log information for debugging
my $bVersion = false;                                               # Display software version
my $bWipeImageDestination = false;                                  # Remove files in default destination path before rendering
my $iWidthOut = undef;                                              # Output file width

GetOptions(
    'date=s@' => \@stryDate,
    'fetch-only' => \$bFetchOnly,
    'file-out=s' => \$strFileOut,
    'format-out=s' => \$strFormatOut,
    'help' => \$bHelp,
    'image=s' => \$strImage,
    'verbose' => \$bVerbose,
    'version' => \$bVersion,
    'wipe-image-dst' => \$bWipeImageDestination,
    'width-out=s' => \$iWidthOut,
) or pod2usage(2);

####################################################################################################################################
# Project variables and paths
####################################################################################################################################
my $strProject = 'Imaginary Cities Image Engine';                   # Software name
my $strProjectVersion = '1.00';                                     # Software version
my $strProjectExe = basename(substr($0, 0, length($0) - 3));        # Exe name used for locks, config files, etc.

my $strBasePath = dirname(dirname(abs_path($0)));                   # Base path containing bin and image directories
my $strImagePath = "${strBasePath}/image";                          # Path where images are stored
my $strImageSrcPath = "${strImagePath}/src";                        # Path for source images
my $strImageDstPath = "${strImagePath}/dst";                        # Default path for image output

my $strLockFile = "/tmp/${strProjectExe}.lock";                     # Lock file (so only one instance is run)
my $strYamlFile = "${strBasePath}/${strProjectExe}.yaml";           # YAML configuration file

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
# Logging function
####################################################################################################################################
sub log
{
    my $strMessage = shift;

    if ($bVerbose)
    {
        print("LOG: ${strMessage}\n");
    }
}

####################################################################################################################################
# Initialization
####################################################################################################################################

# Make sure process is not already running
#-----------------------------------------------------------------------------------------------------------------------------------
sysopen(my $fhLockFile, $strLockFile, O_WRONLY | O_CREAT)
    or confess "unable to open lock file: ${strLockFile}";

flock($fhLockFile, LOCK_EX | LOCK_NB)
    or exit(0);

# Wipe (if requested) and create the image destination directory
#-----------------------------------------------------------------------------------------------------------------------------------
if ($bWipeImageDestination && -e $strImageDstPath)
{
    remove_tree($strImageDstPath) > 0
        or confess "unable to remove ${strImageDstPath}";
}

# No error here because the directory might already exist and that's OK
make_path($strImageDstPath, 0750);

# Parse specified dates (or generate default)
#-----------------------------------------------------------------------------------------------------------------------------------
my $bToday = false;
my $hDayList;

# If dates were passed on the command line
if (@stryDate > 0)
{
    # Loop through all dates
    foreach my $strTargetDay (@stryDate)
    {
        # Error on obviously bogus dates
        if ($strTargetDay !~ /^[0-9]{8}$/)
        {
            confess "--date=${strTargetDay} does not appear to be a date'";
        }

        $hDayList->{$strTargetDay} =
            {year => substr($strTargetDay, 0, 4), month => substr($strTargetDay, 4, 2), day => substr($strTargetDay, 6, 2)};
    }
}
# Else use today (GMT)
else
{
    my ($iCurrentSecond, $iCurrentMinute, $iCurrentHour, $iCurrentMonthDay, $iCurrentMonth, $iCurrentYear) = gmtime(time());
    my $hTargetDay = {year => $iCurrentYear + 1900, month => $iCurrentMonth + 1, day => $iCurrentMonthDay};

    $hDayList->{sprintf('%04d%02d%02d', $hTargetDay->{year}, $hTargetDay->{month}, $hTargetDay->{day})} = $hTargetDay;
    $bToday = true;
}

# Check that if file-out is specified there is an image and only one date
#-----------------------------------------------------------------------------------------------------------------------------------
if (defined($strFileOut) && !(defined($strImage) && keys(%$hDayList) == 1))
{
    confess "--image and one date must be specified with --file-out";
}

# Create user agent for interwebs requests
#-----------------------------------------------------------------------------------------------------------------------------------
my $oInterWebs = LWP::UserAgent->new;
$oInterWebs->agent("${strProjectExe}/$strProjectVersion}");

# Load image data
#-----------------------------------------------------------------------------------------------------------------------------------
my $hyImageData = LoadFile($strYamlFile);

# Connect to PostgreSQL
#-----------------------------------------------------------------------------------------------------------------------------------
(my $oPg = DBI->connect(
    "dbi:Pg:host=$hyImageData->{pgHost};dbname=$hyImageData->{pgDatabase}", $hyImageData->{pgUser}, $hyImageData->{pgPassword},
    {AutoCommit => 1, RaiseError => 0, PrintError => 0, Warn => 0, pg_server_prepare => 1}))
    or confess "unable to connect to database: " . $DBI::errstr;

####################################################################################################################################
# Process all images
####################################################################################################################################
foreach my $hImageData (@{$hyImageData->{imageList}})
{
    # If an image was specified then process only that image
    next if (defined($strImage) && $strImage ne $hImageData->{name});

    # Query database for the image
    #-------------------------------------------------------------------------------------------------------------------------------
    my $iPgImageId = undef;
    my $strPgImageName = undef;
    my $strPgImageUrl = undef;
    my $strPgImageSha1 = undef;
    my $bPgTodayData = false;

    my $oStatement = $oPg->prepare('select id, name, url, sha1 from image.image where id = $1');
    (my $iRowTotal = $oStatement->execute($hImageData->{flickrId}))
        or confess "unable to query '$hImageData->{name}' image data: " . $DBI::errstr;

    if ($iRowTotal > 0)
    {
        ($iPgImageId, $strPgImageName, $strPgImageUrl, $strPgImageSha1) = $oStatement->fetchrow_array();

        # If running for today see if the database already has data
        if ($bToday)
        {
            my $oStatement = $oPg->prepare('select count(*) from image.image_data where image_id = $1 and day = $2::date');
            ($iRowTotal = $oStatement->execute($iPgImageId, (keys(%$hDayList))[0]))
                or confess "unable to query '$hImageData->{name}' today data: " . $DBI::errstr;

            ($bPgTodayData) = $oStatement->fetchrow_array();
        }
    }

    # Get image metadata and save to database if new
    #-------------------------------------------------------------------------------------------------------------------------------
    my $strImageFile = "${strImageSrcPath}/$hImageData->{name}";

    if (!defined($iPgImageId) || ($bToday && !$bPgTodayData) || !-e $strImageFile)
    {
        # Fetch image metadata
        &log("fetching '$hImageData->{name}' page from the interwebs");

        my $oResponse = $oInterWebs->request(
            HTTP::Request->new(GET => "https://www.flickr.com/photos/britishlibrary/$hImageData->{flickrId}"));

        $oResponse->is_success
            or confess "unable to get '$hImageData->{name}' page: " . $oResponse->status_line;

        # Extract image metadata
        my $strImageMetaTag = 'modelExport';
        my $strImageMeta = ($oResponse->content =~ m/^\s*$strImageMetaTag\:\s*\{.*\}\,$/gm)[0];
        $strImageMeta =~ s/^\s+|\s+$//g;
        my $hyImageMeta = JSON::PP->new()->allow_nonref()->decode(
            substr($strImageMeta, length($strImageMetaTag) + 2, length($strImageMeta) - length($strImageMetaTag) - 3));

        # Get view count
        (my $iWebImageView = $hyImageMeta->{'main'}{'photo-models'}[0]{'engagement'}{'viewCount'})
            or die "unable to extract '$hImageData->{name}' view count";
        $iWebImageView = int($iWebImageView);

        # Get original image url
        (my $strWebImageUrl = $hyImageMeta->{'main'}{'photo-models'}[0]{'sizes'}{'o'}{'url'})
            or die "unable to extract '$hImageData->{name}' original image url";
        $strWebImageUrl = "https:${strWebImageUrl}";

        # Get keywords
        (my $strWebImageKeyword = $hyImageMeta->{'main'}{'photo-head-meta-models'}[0]{'keywords'})
            or die "unable to extract '$hImageData->{name}' keywords";
        $strWebImageKeyword = uri_unescape($strWebImageKeyword);

        &log(
            "fetched '$hImageData->{name}' page: view count = ${iWebImageView}, url = ${strWebImageUrl}" .
                ", keyword count = " . split(", ", $strWebImageKeyword));

        # If the image does not already exist in the cache then fetch it
        #---------------------------------------------------------------------------------------------------------------------------
        my $strWebImageSha1 = undef;

        if (!-e $strImageFile || !defined($iPgImageId))
        {
            &log("fetching '$hImageData->{name}' image from the interwebs");

            my $oResponse = $oInterWebs->request(HTTP::Request->new(GET => $strWebImageUrl));

            $oResponse->is_success
                or confess "unable to get '$hImageData->{name}' original image: " . $oResponse->status_line;

            $strWebImageSha1 = sha1_hex($oResponse->content);

            # Write the image to cache
            make_path($strImageSrcPath, {mode => 0640});

            sysopen(my $hFile, $strImageFile, O_WRONLY | O_CREAT | O_TRUNC, 0750)
                or die "unable to open '${strImageFile}' for write";

            syswrite($hFile, $oResponse->content)
                or die "unable to write '${strImageFile}'";

            $hFile->sync()
                or die "unable to sync '${strImageFile}'";

            close($hFile)
                or die "unable to close '${strImageFile}'";

            &log("fetched '$hImageData->{name}' image: sha1 = ${strWebImageSha1}");
        }

        # Insert image and data into the database
        #---------------------------------------------------------------------------------------------------------------------------
        if (!defined($iPgImageId))
        {
            $iPgImageId = $hImageData->{flickrId};
            $strPgImageName = $hImageData->{name};
            $strPgImageUrl = $strWebImageUrl;
            $strPgImageSha1 = $strWebImageSha1;

            my $oStatement = $oPg->prepare('insert into image.image (id, name, url, sha1) values ($1, $2, $3, $4)');
            $oStatement->execute($iPgImageId, $strPgImageName, $strPgImageUrl, $strPgImageSha1)
                or confess "unable to insert '$hImageData->{name}' image data: " . $DBI::errstr;
        }

        if ($bToday && !$bPgTodayData)
        {
            my $oStatement = $oPg->prepare('insert into image.image_data (image_id, day, view, keyword) values ($1, $2, $3, $4)');
            $oStatement->execute($iPgImageId, (keys(%$hDayList))[0], $iWebImageView, $strWebImageKeyword)
                or confess "unable to insert '$hImageData->{name}' image data: " . $DBI::errstr;
        }
    }

    # When fetch-only move to the next image
    #-------------------------------------------------------------------------------------------------------------------------------
    next if $bFetchOnly;

    # Open image
    #-------------------------------------------------------------------------------------------------------------------------------
    my $oBaseImage = Imager->new();

    $oBaseImage->read(file => $strImageFile)
        or confess $oBaseImage->errstr;

    # Convert to greyscale
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

    # Loop through specified dates
    #-------------------------------------------------------------------------------------------------------------------------------
    foreach my $strTargetDay (sort(keys(%$hDayList)))
    {
        # Get image metadata and generate hash
        #---------------------------------------------------------------------------------------------------------------------------
        my $oStatement = $oPg->prepare(
            "with target as\n" .
            "(\n" .
            "    select \$1::bigint as image_id,\n" .
            "           \$2::date as day\n" .
            ")\n" .
            "select first.day as first_day,\n" .
            "       last.day as last_day,\n" .
            "       (((last.view - first.view)::numeric / (last.day - first.day + 1)::numeric *\n" .
            "         (target.day - first.day + 1)::numeric) + first.view)::bigint as view,\n" .
            "       last.keyword\n" .
            "  from target\n" .
            "       left outer join image.image_data first\n" .
            "            on first.image_id = target.image_id\n" .
            "           and first.day =\n" .
            "           (\n" .
            "               select max(day)\n" .
            "                 from image.image_data\n" .
            "                where image_data.image_id = target.image_id\n" .
            "                  and image_data.day <= target.day\n" .
            "           )\n" .
            "       left outer join image.image_data last\n" .
            "            on last.image_id = target.image_id\n" .
            "           and last.day =\n" .
            "           (\n" .
            "               select min(day)\n" .
            "                 from image.image_data\n" .
            "                where image_data.image_id = target.image_id\n" .
            "                  and image_data.day >= target.day\n" .
            "           )");

        ($oStatement->execute($iPgImageId, $strTargetDay))
            or confess "unable to query '$hImageData->{name}' image data: " . $DBI::errstr;

        my ($strFirstDay, $strLastDay, $iImageView, $strImageKeyword) = $oStatement->fetchrow_array();

        # Error if the day is too early or too late
        $strFirstDay
            or confess "target date is before earliest date in database";

        $strLastDay
            or confess "target date is after latest date in database";

        # Generate hash
        my $tHash = sha1("${iImageView}-${strImageKeyword}");
        my $iHashByteIdx = 0;

        # Calculate permutation and up to seven pixel perturbation
        #---------------------------------------------------------------------------------------------------------------------------
        my $hTargetDay = $hDayList->{$strTargetDay};

        my $iLoopX = $hImageData->{cropWidth} - $hImageData->{rectangle} + 1;
        my $iLoopY = $hImageData->{cropHeight} - $hImageData->{rectangle} + 1;

        my $iPermutationTotal = ($iLoopX * $iLoopY) / 8;
        my $iPermutation = julian_day($hTargetDay->{year}, $hTargetDay->{month}, $hTargetDay->{day}) % $iPermutationTotal;

        my $iOffset =
            (($iLoopX * $iLoopY) / $iPermutationTotal) * $iPermutation +
            int(unpack('C', substr($tHash, $iHashByteIdx++, 1)) & 0x07);
        my $iOffsetX = $iOffset % $iLoopX;
        my $iOffsetY = int(($iOffset - $iOffsetX) / $iLoopX);

        &log(
            "$hImageData->{name} $strTargetDay, iLoopX = $iLoopX, iLoopY = $iLoopY, iPermutation = $iPermutation" .
            ", iTotalOffset = " . ($iLoopX * $iLoopY) . ", iOffset = $iOffset, iOffsetX = $iOffsetX, iOffsetY = $iOffsetY");

        # Crop image based on permutation
        #---------------------------------------------------------------------------------------------------------------------------
        my $oImage = $oBaseImage->crop(
            left => $hImageData->{cropLeft} + $iOffsetX, top => $hImageData->{cropTop} + $iOffsetY,
            width => $hImageData->{rectangle}, height => $hImageData->{rectangle})
            or confess $oBaseImage->errstr;

        # Scale to output size
        #---------------------------------------------------------------------------------------------------------------------------
        my $iImageWidthOut = $iWidthOut;

        if (!defined($iImageWidthOut))
        {
            $iImageWidthOut = defined($hImageData->{outWidth}) ? $hImageData->{outWidth} : $hyImageData->{outWidth};
        }

        $oImage = $oImage->scale(xpixels => $iImageWidthOut / 2)
            or confess $oImage->errstr;

        # Apply filters
        #---------------------------------------------------------------------------------------------------------------------------
        foreach my $hFilter (@{$hImageData->{filterList}})
        {
            # Loop through all filters
            for my $strFilterParam (sort(keys(%{$hFilter})))
            {
                # Make sure there are still bytes left in the hash
                if ($iHashByteIdx >= length($tHash))
                {
                    confess "no more bytes in the hash to use for filter perturbations";
                }

                # Apply +/- 10% pertubation to filter parameters
                if ($strFilterParam ne 'type')
                {
                    $hFilter->{$strFilterParam} +=
                        $hFilter->{$strFilterParam} *
                        (int(unpack('C', substr($tHash, $iHashByteIdx, 1))) & 0x80 ? 1 : -1) *
                        (int(unpack('C', substr($tHash, $iHashByteIdx, 1))) % 11) / 100;
                    $iHashByteIdx++;
                }
            }

            # Apply filter
            $oImage = $oImage->filter(%{$hFilter})
                or confess $oImage->errstr;
        }

        # Create collage by rotating and combining images to produce a mandala
        #---------------------------------------------------------------------------------------------------------------------------
        my $oCollage = Imager->new(xsize => $iImageWidthOut, ysize => $iImageWidthOut);

        for (my $iIndex = 0; $iIndex < 4; $iIndex++)
        {
            my $iX = $iIndex == 1 || $iIndex == 2 ? $iImageWidthOut / 2 : 0;
            my $iY = $iIndex == 2 || $iIndex == 3 ? $iImageWidthOut / 2 : 0;
            my $strDirection = $iIndex == 1 || $iIndex == 3 ? 'h' : ($iIndex == 2 ? 'v' : undef);

            $oCollage->rubthrough(
                src => (defined($strDirection) ? $oImage->flip(dir => $strDirection) : $oImage), tx => $iX, ty => $iY);
        }

        $oCollage->compose(src => $oCollage->rotate(degrees => 90), opacity => 0.5);

        $oCollage->write(
            file => defined($strFileOut) ?
                $strFileOut : "${strImageDstPath}/$hImageData->{name}-collage-${strTargetDay}.${strFormatOut}",
            tiff_compression => 5, jpegquality => 90)
            or confess $oImage->errstr;
    }
}

####################################################################################################################################
# Remove and close the lock file (ignore any failures because the kernel will still release the lock)
####################################################################################################################################
unlink($strLockFile);
close($fhLockFile);
