#!/usr/bin/perl
# Author: Chris Eberle <eberle1080@gmail.com>

use File::Find ();
use File::stat;
use File::Basename;
use Getopt::Long;
use String::ShellQuote;
use Digest::MD5;
use threads;
use Thread::Semaphore;

# Variables you should change to suit your preferences
our $in_dir = "/data/media/music";
our $out_dir = "/data/media/ipod";
our $quality = "2";
our $channels = "j";
our $bitrate = "128";
our $thread_count = 2;

# Variables you can tweak if you want
our $err_color : shared  = "\033[01;35m"; # Purple
our $enc_color : shared  = "\033[01;32m"; # Green
our $skip_color : shared = "\033[01;34m"; # Blue
our $del_color : shared  = "\033[01;31m"; # Red
our $end_color : shared  = "\033[00m";    # Clear

# Don't touch these
our $semaphore : shared = new Thread::Semaphore;
our $console : shared = 0;
our %file_list : shared;
our %thread_list : shared;
our $threadnum : shared;
my $do_delete = 1;

# Configure things
my $temp_in = $in_dir;
my $temp_out = $out_dir;
GetOptions("quality:i" => \$quality,
           "in:s" => \$in_dir,
           "out:s" => \$out_dir);

if(!($temp_in eq $in_dir) || !($temp_out eq $out_dir))
{
    $do_delete = 0;
}

# build genre hash
our %genres;
open(GENRES, "/usr/bin/lame --genre-list 2>&1 |") or die "Couldn't get genre list with /usr/bin/lame --genre-list\n";
while(<GENRES>) {
    chomp;
    next if /^\s*$/;
    # lowercase names are keys, ID number is value
    $genres{lc($2)} = $1 if /^\s*(\d*)\s(.*)$/;
}
close(GENRES);

# Run the (very short) main program
my @pending = ();

$threadnum = 0;
for(my $n = 1; $n < $thread_count; $n++) { $semaphore->up(); $thread_list{"$n"} = "1"; }
$thread_list{"$thread_count"} = "1";
print "Finding files...\n";
File::Find::find({wanted => \&wanted}, $in_dir);
@pending_sorted = sort { lc($a) cmp lc($b) } @pending;
print "Encoding files...\n";
print "Lame options: -r -q $quality -b $bitrate -s 44.1 -m $channels\n";
foreach(@pending_sorted) { process_file($_); }

for(my $n = 0; $n < $thread_count; $n++) { $semaphore->down(); }
for(my $n = 0; $n < $thread_count; $n++) { threads->yield(); }
print "Waiting 1 second for threads to finish\n";
sleep 1;
if($do_delete)
{
    print "Removing files...\n";
    File::Find::find({wanted => \&wanted_delete}, $out_dir);
    print "Removing empty directories...\n";
    File::Find::finddepth(sub { rmdir $_; }, $out_dir);
}
print "Done!\n";
exit 0;

# Find all *.ogg files
sub wanted {
    my ($dev,$ino,$mode,$nlink,$uid,$gid);

    (($dev,$ino,$mode,$nlink,$uid,$gid) = lstat($_)) &&
    -f _ &&
    /^.*\.ogg\z/si && push(@pending, $File::Find::name);
}

# Start a thread to encode an ogg file to an mp3 file
sub process_file
{
    my $file = @_[0];
    $semaphore->down();

    {
        lock(%main::thread_list);
        for(my $n = 1; $n <= ${main::thread_count}; $n++)
        {
            #print "\$main::thread_list{$n} = " . $main::thread_list{"$n"} . "\n";
            if($main::thread_list{"$n"} == "1")
            {
                $main::thread_list{"$n"} = "0";
                my $thread = threads->new(\&run_encode, $file, $n);
                $thread->detach();
                return;
            }
        }
    }

    $semaphore->up();
}

# Thread method for encoding a file
sub run_encode
{
    my $num = @_[1];
    encode_file(@_[0], $num);

    {
        lock(%main::thread_list);
        $main::thread_list{"$num"} = "1";
    }

    $semaphore->up();
}

# Encode an ogg file into an mp3 file. If the file already exists, skip it.
sub encode_file
{
    my $oggfile = @_[0];
    my $tnum = @_[1];

    # Make sure the file exists
    if(! -e $oggfile)
    {
        lock($console);
        print "Error: ${main::err_color}'$oggfile' does not exist!${main::end_color}\n";
        return;
    }

    # Read the ogg tags
    if(!open(TAGS, "/usr/bin/ogginfo \Q$oggfile\E |"))
    {
        lock($console);
        print "Error: ${main::err_color}Couldn't run ogginfo $oggfile${main::end_color}\n";
        return;
    }

    # Put the tags into an array
    while(<TAGS>)
    {
        chomp;
        next if /^\s*$/;

        # get title tags
        if (/^\s*(\S+)=(.*)$/) {
            $oggtags{lc($1)} = $2;
        }
    }
    close(TAGS);

    # Create the filename, and mp3 tags
    my $renamed_artist = $oggtags{"artist"};
    if($renamed_artist =~ m/^(the) (.*)$/i)
    {
        $renamed_artist = $2 . ", " . $1;
    }
    my $m4aoutputfile = "$out_dir/" . sanitize($renamed_artist) . "/";
    if($oggtags{"date"}) { $m4aoutputfile .= sanitize($oggtags{"date"}) . " - "; }
    elsif($oggtags{"year"}) { $m4aoutputfile .= sanitize($oggtags{"year"}) . " - "; }
    if($oggtags{"album"}) { $m4aoutputfile .= sanitize($oggtags{"album"}); }
    else { $m4aoutputfile .= "Untitled"; }
    $m4aoutputfile =~ s/\.\//\//;
    system("mkdir -p " . shell_quote($m4aoutputfile));
    $m4aoutputfile .= "/";
    $m4aoutputfile .= sanitize(sprintf("%02d", $oggtags{"tracknumber"})) . " - " . sanitize($oggtags{"title"}) . ".mp3";
    $m4aoutputfile =~ s/\.\//\//;

    {
        lock(%file_list);
        $main::file_list{"$m4aoutputfile"} = "1";
    }

    # Check to see if the mp3 already exists
    if(-e $m4aoutputfile)
    {
        lock($console);
        print STDERR "Skipping: ${main::skip_color}${m4aoutputfile}${main::end_color}\n";
        return;
    }
    else
    {
        # It doesn't exist, so encode it
        $m4aoutputfile_escaped = shell_quote($m4aoutputfile);
        $oggfile_escaped = shell_quote($oggfile);

        my $artist = shell_quote($oggtags{"artist"});
        my $date;
        if($oggtags{"date"}) { $date = shell_quote($oggtags{"date"}); }
        else { $date = shell_quote($oggtags{"year"}); }
        my $album = shell_quote($oggtags{"album"});
        my $title = shell_quote($oggtags{"title"});
        my $genre = shell_quote($oggtags{"genre"});
        my $track = shell_quote(sprintf("%d", $oggtags{"tracknumber"}));
        my $comment;
        if($oggtags{"comment"}) { $comment = shell_quote($oggtags{"comment"}); }
        else { $comment = shell_quote($oggtags{"description"}); }

        # Make the command line options for the tags
        my $infostring = "";
        if($artist ne "") {
            $infostring .= "--ta " . $artist;
        }
        if($album ne "") {
            $infostring .= " --tl " . $album;
        }
        if($title ne "") {
            $infostring .= " --tt " . $title;
        }
        if($track ne "") {
            $infostring .= " --tn " . $track;
        }
        if($date ne "") {
            $infostring .= " --ty " . $date;
        }
        if($genre ne "") {
            # need to lowecase ogg tag for match
            my $genretag = lc($genre);

            # ogg has spaces in genres underscored, removing them
            $genretag =~ s/_/ /g;

            # lookup converted string in genre hash, get ID number
            $genretag = $genres{$genretag};

            # damn, those crazy lame guys use 0 as ID, thanks a bundle
            if ($genretag ne "" && ($genretag || ($genretag == 0))) {
                $infostring .= " --tg " . $genretag;
            }
        }

        $command = "/usr/bin/ogg123 -q -d raw -f - $oggfile_escaped | \$(/usr/bin/lame -r -q $quality -b $bitrate -s 44.1 -m $channels $infostring - $m4aoutputfile_escaped > /dev/null 2>&1)";
        {
            lock($console);
            print "Encoding [$tnum]: ${main::enc_color}${m4aoutputfile}${main::end_color}\n";
        }

        system($command);
    }

    return;
}

# Make filenames nice for certain M$ file systems
sub sanitize
{
    my $text = shift;

    $text =~ s/[\/\\:]/-/g;
    $text =~ s/[#\$\%^\~\*\|\@]/_/g;
    $text =~ s/[\?!]//g;
    $text =~ s/[&]/ And /g;
    $text =~ s/[\s]{2,}And/ And/g;
    $text =~ s/And[\s]{2,}/And /g;
    $text =~ s/[\]>\}]/\)/g;
    $text =~ s/[\[<\{]/\(/g;
    $text =~ s/\"/\'/g;
    $text =~ s/é/e/g;

    return $text;
}

# Find unused files to delete
sub wanted_delete
{
    my ($dev,$ino,$mode,$nlink,$uid,$gid);

    (($dev,$ino,$mode,$nlink,$uid,$gid) = lstat($_)) &&
    -f _ &&
    /^.*\.m4a\z/si && delete_file($_);
}

# If a file exists that shouldn't be there, delete it.
sub delete_file
{
    my $file = $File::Find::name;
    if(!$main::file_list{"$file"})
    {
        print "Removing: ${main::del_color}${file}${main::end_color}";
        my $command = "rm -f " . shell_quote($file);
        if(system($command))
        {
            print "${main::err_color} FAILED${main::end_color}\n";
        }
        else
        {
            print "\n";
        }
    }
}
