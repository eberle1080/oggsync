#!/usr/bin/perl

use File::Find ();
use File::stat;
use File::Basename;
use Getopt::Long;
use String::ShellQuote;
use Digest::MD5;
use threads;
use Thread::Semaphore;

# Variables you should change to suit your preferences
my $in_dir = "/data/audio/music";
my $out_dir = "/data/audio/ipod";
my $quality = "100";
my $thread_count = 2;

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

# Run the (very short) main program
print "Encoding files...\n";
for(my $n = 1; $n < $thread_count; $n++) { $semaphore->up(); }
File::Find::find({wanted => \&wanted}, $in_dir);
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
    /^.*\.ogg\z/si && process_file($_, $quality);
}

# Start a thread to encode an ogg file to an mp4 file
sub process_file
{
    my $file = $File::Find::name;
    $semaphore->down();
    my $thread = threads->new(\&run_encode, $file, @_[1]);
    $thread->detach();
}

# Thread method for encoding a file
sub run_encode
{
    encode_file(@_[0], @_[1]);
    $semaphore->up();
}

# Encode an ogg file into an mp4 file. If the file already exists, skip it.
sub encode_file
{
    my $oggfile = @_[0];
    my $qual = @_[1];

    if(! -e $oggfile)
    {
        lock($console);
        print "Error: ${main::err_color}'$oggfile' does not exist!${main::end_color}\n";
        return;
    }

    if(!open(TAGS, "/usr/bin/ogginfo \Q$oggfile\E |"))
    {
        lock($console);
        print "Error: ${main::err_color}Couldn't run ogginfo $oggfile${main::end_color}\n";
        return;
    }

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
    $m4aoutputfile .= sanitize(sprintf("%02d", $oggtags{"tracknumber"})) . " - " . sanitize($oggtags{"title"}) . ".m4a";
    $m4aoutputfile =~ s/\.\//\//;

    {
        lock(%file_list);
        $main::file_list{"$m4aoutputfile"} = "1";
    }

    if(-e $m4aoutputfile)
    {
        lock($console);
        print "Skipping: ${main::skip_color}${m4aoutputfile}${main::end_color}\n";
        return;
    }

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

    $command = "/usr/bin/ogg123 -q -d raw -o byteorder:big -f - $oggfile_escaped | \$(/usr/bin/faac -P -q $qual -o $m4aoutputfile_escaped --artist $artist --year $date --album $album --title $title --genre $genre --track $track --comment $comment - > /dev/null 2>&1)";

    {
        lock($console);
        print "Encoding: ${main::enc_color}${m4aoutputfile}${main::end_color}\n";
    }

    system($command);
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

