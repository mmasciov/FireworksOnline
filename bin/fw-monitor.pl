#!/usr/bin/env perl 
#

use strict;

use File::Copy;
use Proc::Killfam;
use POSIX qw( WNOHANG );
use Net::Domain qw(hostname hostfqdn hostdomain domainname);

# Variables from config file:
use vars qw
    ($FW_ENABLED $FW_DISPLAY
     $FW_NEW_FILE_NOTIFICATION $FW_NOTIFY_NEW_FILE_TIMEOUT
     $FW_PORT $FW_DATA_DIR $FW_DEBUG
     $FW_SCP_CMSSHOW_IMAGE_ENABLE $FW_SCP_DESKTOP_IMAGE_ENABLE
     $FW_TRANSFER_IMAGE_TIMEOUT 
     $FW_SCP_TARGET $FW_MAIL_LIST);


my $cmsShow_pid = 0;

# get base directory
die ("Can't start the fw-monitor.pl script without base directory argument.") unless (@ARGV == 1);
my $FW_DIR = $ARGV[0];
die ("Can't read configuration at $FW_DIR/bin/fw-config.txt") unless ( -r "$FW_DIR/bin/fw-config.txt");


###############################################################################
# FUNCTIONS  
###############################################################################

sub fwQuit
{
  my $msg = shift;

  print $msg;

  if ($cmsShow_pid) {
    killfam 'KILL', $cmsShow_pid; 
  }

  exit;
}

sub debugPrint
{
  my $message = shift;
  if ($FW_DEBUG) {
    my $currentTime = localtime();
    print("$currentTime $message");
  }
}

$SIG{TERM} = sub
{
  fwQuit ("kill child fw-cmsShow-command \n");
};

sub writeLineToFile
{
  # Write a file with one line.

  my ($line, $filename) = @_;

  open F, ">$filename" or fwQuit "Can't write_line_to_file!";
  print F $line, "\n";
  close F;
}

sub readLineFromFile
{
  # Returns the first line from file or "" if the file does not exist.
  # Dies if file can not be opened for reading.

  my $filename = shift;
  return "" unless -e $filename;
  open F, $filename or fwQuit("Can't read_line_from_file!");
  my $line = <F>;
  close F;
  chomp $line;
  return $line;
}


sub setMonitorLog
{
   # remove old log files
   {
     my $wktime=time();
     my $maxAge=1209600;
     my $DIR;
     opendir (DIR, "$FW_DIR/log/");
     while (my $file = readdir DIR) {
       if ( "$file" =~ m/((?:monitor)|(?:cmsShow))\.\d+\.log/ )  {
	 my $mtime = (stat "$FW_DIR/log/$file")[9];
	 my $dif = $wktime - $mtime ;
	 if ($dif > $maxAge) {
	   print($wktime, " remove old log $file with age $dif \n");
  	   unlink "$FW_DIR/log/$file";
	 }
       }
     }
   }

   # remove old symbolic lik
   if ( -l "${FW_DIR}/log/monitor.log") { unlink("${FW_DIR}/log/monitor.log") };

   # set log file
   my $mpid=$$;
   my $monitorLogFile = "${FW_DIR}/log/monitor.${mpid}.log";
   if (1) {
      open STDOUT, '>>', $monitorLogFile or fwQuit "fw-monitor: Can't redirect STDOUT: $!";
      open STDERR, ">&STDOUT" or fwQuit "fw-monitor: Can't dump STDOUT: $!";
   }

   symlink( $monitorLogFile, "${FW_DIR}/log/monitor.log");

   my $now = localtime();
   print( "$now Starting fw-monitor with pid $$ \n");
}

sub setDisplay
{
  if (length($FW_DISPLAY)) {
    print "Set DISPLAY variable from fw-config to $FW_DISPLAY \n"; 
    $ENV{DISPLAY}=$FW_DISPLAY;
  }
  else
  {    
    print "Set DISPLAY to default value :0 \n"; 
    $ENV{DISPLAY}=":0";
  }
}


sub notifyNewDataFile
{
  my $fw_file = shift;

  my $afsFileName = readLineFromFile("$FW_DATA_DIR/Log/LastFile");

  my $ntime = localtime();
  my $afsFileTimeStamp = localtime((stat $afsFileName)[9]);
  print ("$ntime Check new file every $FW_NOTIFY_NEW_FILE_TIMEOUT seconds. Looking at $FW_DATA_DIR/Log/LastFile.\nLatest reconstructed file $afsFileName updated at $afsFileTimeStamp.\n");
 
  if (($afsFileName =~ m/\.root$/o) && ($$fw_file ne $afsFileName) )
  {
    printf("Notify new file $afsFileName \n"); 
    system(" echo $afsFileName | nc -w 10 localhost $FW_PORT");
    $$fw_file = $afsFileName;
  }
}

sub provideImages
{  
  # get scp guest and user name from configuration
   
  my $scpTarget = shift; 
  my $old_screenshot = shift;

  my $scpHost;
  my $scpDir;
  if ($scpTarget =~ m/([a-zA-Z0-9]+)@(.*):(.*)/o)
  {
    $scpHost = "$1"."\@"."$2";
    $scpDir = $3;
  }
  else
  {
    fwQuit("Can't get valid scp host from $scpTarget.");
  }

  # get latest series of images produced with cmsShow option --auto-save-all-views
  my $ssDir="$FW_DIR/screenshots";
  
  # get latest file and remove file more than fice days old
  opendir(my $dh, $ssDir);
  my $maxAge = 3600*24*5;
  my $minTimeDifVal = $maxAge;
  my $minTimeDifFile;
  my $ktime = time();
  
  my $fexp='(.*)_(\d+)_(\d+)_(\d+)_([a-zA-Z0-9]+)(_\d)?.png';
   
  while (my $file = readdir $dh) {
    if ( $file =~ /$fexp/o ) {
      my $mtime = (stat "${ssDir}/${file}")[9];
      my $dif = $ktime -  $mtime;

      if ($dif > $maxAge) {
	print ("remove old screenshot $file \n");
	unlink "${ssDir}/${file}";
	next;
      }

      if ($dif < $minTimeDifVal) {
	$minTimeDifVal  = $dif;
	$minTimeDifFile = $file;
      }
    }
  }
  closedir($dh);


  if ($FW_SCP_CMSSHOW_IMAGE_ENABLE) {  
    # scp images from latest event 
    unless ("${ssDir}/${minTimeDifFile}" eq $$old_screenshot)
    {
      opendir(my $dh, $ssDir);
      if ($minTimeDifFile =~ m/$fexp/o)
      {
	my $base="$1_$2_$3_$4";
	sleep 1; # wait in case all images are not produced
	while (my $newImg = readdir $dh) {
	  next unless ( $newImg =~ m/${base}/);
	  if ($newImg=~ m/$fexp/o)
	  {
	    my $stdName = "$5$6.png";
	    copy("${ssDir}/${newImg}", "${ssDir}/${stdName}") or fwQuit "Copy [${ssDir}/${newImg}] [${ssDir}/${stdName}] failed: $!";
#NoSCP	    if ( -r "$ENV{HOME}/.ssh/image_transfer" )
#NoSCP	    {
#NoSCP	      my $newStdName = "new-$stdName";
#NoSCP
#NoSCP	      debugPrint("scp $newImg as ${newStdName} \n"); 
#NoSCP	      system("scp -i $ENV{HOME}/.ssh/image_transfer ${ssDir}/${stdName} ${scpTarget}/${newStdName}");
#NoSCP	      system("ssh -i $ENV{HOME}/.ssh/image_transfer ${scpHost} \"mv ${scpDir}/${newStdName} ${scpDir}/${stdName}\"");
#NoSCP	      if ( $6 eq "_1" ) {
#NoSCP	        system("ssh -i $ENV{HOME}/.ssh/image_transfer ${scpHost} \"cp ${scpDir}/${stdName} ${scpDir}/$5.png\"");
#NoSCP	      }
#NoSCP	    }
#NoSCP	    else {
#NoSCP	      print("Can't scp images to web server.\n");
#NoSCP	    }
	    # also copy to new area
	    debugPrint("copying ${ssDir}/${newImg} as /eventdisplayweb/images/scx5scr41/${stdName} \n");
	    #copy("${ssDir}/${stdName}", "/eventdisplayweb/images/scx5scr41/${stdName}") or fwQuit "Copy [${ssDir}/${stdName}] [/eventdisplayweb/images/scx5scr41/${stdName}] failed: $!";
	    copy("${ssDir}/${stdName}", "/eventdisplayweb/images/scx5scr41/${stdName}") or print("Copy [${ssDir}/${stdName}] [/eventdisplayweb/images/scx5scr41/${stdName}] failed: $! \n");
	  }
	}
      }
      $$old_screenshot = "${ssDir}/${minTimeDifFile}";
      closedir($dh);
    }
  }

  # create xwd screenshot
  if ($FW_SCP_DESKTOP_IMAGE_ENABLE) {
    my $xwdName = "xwd-root.png";
    my $newXwdName = "new-$xwdName";
    #    system("xwd -root | convert - ${ssDir}/${xwdName}");
    system("xwd -root | convert - -fill black -draw 'rectangle 0,0,1280,2160' ${ssDir}/${xwdName}");  

#NoSCP    debugPrint("scp -i $ENV{HOME}/.ssh/image_transfer  ${ssDir}/${xwdName}  ${scpTarget}/${newXwdName} \n");
#NoSCP    system("scp -i $ENV{HOME}/.ssh/image_transfer  ${ssDir}/${xwdName}  ${scpTarget}/${newXwdName}");
#NoSCP    system("ssh -2 -i $ENV{HOME}/.ssh/image_transfer  ${scpHost} \"mv ${scpDir}/${newXwdName} ${scpDir}/${xwdName}\"");
    # also copy to new area
    debugPrint("copying ${ssDir}/${xwdName} as /eventdisplayweb/images/scx5scr41/${xwdName} \n");
    #copy("${ssDir}/${xwdName}", "/eventdisplayweb/images/scx5scr41/${xwdName}") or fwQuit "Copy [${ssDir}/${xwdName}] [/eventdisplayweb/images/scx5scr41/${xwdName}] failed: $!";
    copy("${ssDir}/${xwdName}", "/eventdisplayweb/images/scx5scr41/${xwdName}") or print("Copy [${ssDir}/${xwdName}] [/eventdisplayweb/images/scx5scr41/${xwdName}] failed: $! \n");
    
  }
}


###############################################################################
# MAIN
###############################################################################
{
  # check or save monitor PID
  my $monitor_pid_file="$FW_DIR/log/monitor_pid";
  if ( -r $monitor_pid_file) {
    my $oldPid= readLineFromFile($monitor_pid_file);
    if ((-r "/proc/$oldPid") && ( readLineFromFile("/proc/$oldPid/cmdline") =~ m/fw-monitor/))
    {
      exit 0;
    }
  }

  # write current PID
  writeLineToFile($$, $monitor_pid_file);

  # setup env
  setMonitorLog();
  do "$FW_DIR/bin/fw-config.txt";
  setDisplay();
   
  # set scp target from matching domain
  my $domain =  hostdomain();
  my $scpTarget;
  for my $sx (split(/\s+/, $FW_SCP_TARGET)) {
    if ($sx =~ m/$domain/) {
      $scpTarget = $sx;
      last;
    }
  } 
  fwQuit("Can't locate scp target from domain\n") unless (length($scpTarget));

  # build maillist for current domain
  my $hname = domainname();
  my $mlist;
  {
    my $dname = hostdomain();
    foreach my $address (split(/\s+/,  $FW_MAIL_LIST)) {
      if ( $address =~ m/$dname/) {
	$mlist .= "${address} ";
      }
    }
  }

  my $cmsShow_cnt = 60;
  my $live_cnt    = 0;
  my $feeder_cnt  = 0;
  my $img_cnt     = 0;
  
  my $latest_screenshot;
  my $latest_data_file;

  while (1) {
    # print "Entering THE loop\n";

    # check in case some has edited external config (e.g. call fireworksOnline --stop/start)
    do "$FW_DIR/bin/fw-config.txt";

    if ($FW_ENABLED == 0)
    {
      fwQuit("event display was disabled. Exit ...\n");
    }
    else 
    {
      {
	my $pid = waitpid(-1, WNOHANG);
	if ($cmsShow_pid != 0 && $pid == $cmsShow_pid)
	{
	  if ($? != 0)
	  {
	    printf("\nERROR: cmsShow exited unexpectedly! See $FW_DIR/log/cmsShow.${cmsShow_pid}.log  !\n");
            my $msg = "Look for details in $hname $FW_DIR/log/cmsShow.${cmsShow_pid}.log";	  
	    system(" echo $msg | mail -s ${hname}::cmsShow-crash-report $mlist");
	  }
	  else
	  {
	    print "\nINFO: cmsShow child process exit.\n";
	  }
	  $cmsShow_pid = 0;
	}
	elsif ($pid == 0)
	{
	  debugPrint "waitpid -- processes still running\n";
	}
	elsif ($pid == -1)
	{
	  debugPrint "waitpid error -- errno $!\n";
	}
	else
	{
	  debugPrint "waitpid reaped process $pid\n";
	}
      }

      if ( $cmsShow_pid == 0 &&  $cmsShow_cnt >= 60 )
      {
	my $header = localtime();
	print ("$header Fireworks was not running and will be started...\n");
	if (-l "$FW_DIR/log/cmsShow.log" ) { unlink "$FW_DIR/log/cmsShow.log"; }

	$ENV{FW_DIR}  = $FW_DIR;   
	$ENV{FW_PORT} = $FW_PORT;

	my $afsFile         = readLineFromFile("$FW_DATA_DIR/Log/LastFile");
	my $cmsShow_command = "$FW_DIR/bin/fw-cmsShow-command $afsFile";

	$cmsShow_pid = fork();
	if ($cmsShow_pid == 0)
	{
	  exec($cmsShow_command) or fwQuit "Failed to execute $cmsShow_command";
	}
	print("pid after fork [$cmsShow_pid]  ==========================================\n");
	writeLineToFile($cmsShow_pid, "$FW_DIR/log/cmsShow_pid");
	$cmsShow_cnt = 0;
      }

      system("ps -C cmsShow.exe -o pid=,command=");

      # notify new files
      if ($FW_NEW_FILE_NOTIFICATION && ($feeder_cnt >= $FW_NOTIFY_NEW_FILE_TIMEOUT))
      {
	notifyNewDataFile(\$latest_data_file);
	$feeder_cnt = 0;
      }
      
      # check for new images
      if ($img_cnt >= $FW_TRANSFER_IMAGE_TIMEOUT)
      {
	debugPrint ("Check new screenshots every $FW_TRANSFER_IMAGE_TIMEOUT \n");
	provideImages($scpTarget, \$latest_screenshot);
	$img_cnt = 0;

	# send status info to scp host and a warning mail if delay is more than 20 min
	my $time =  time();
	my $dtime = (stat "$latest_data_file")[9];
	my $stime = (stat "$latest_screenshot")[9];
	if ($live_cnt >= 1200) {
	  my $delay = $time - $stime;
	  if ($delay >= 1200)
	  {
            my $dmin = int(${delay}/60);
	    printf("\nWARNING:$dmin minutes delay to load new data!\n");
	    my $scalar_stime = localtime($stime);
	    my $scalar_dtime = localtime($dtime);
	    my $msg = "Last reconstructed file more than $dmin min delayed: Latest screenshot $latest_screenshot created at $scalar_stime. Last reconstructed file $latest_data_file modified at $scalar_dtime.";
	  
	    system(" echo $msg | mail -s ${hname}::cmsShow-warning $mlist");
	  }
	  $live_cnt = 0;
	}
	if ($FW_SCP_CMSSHOW_IMAGE_ENABLE || $FW_SCP_DESKTOP_IMAGE_ENABLE ) {
	  writeLineToFile("$time $dtime $stime", "/tmp/fwStatusInfo");
	  system("scp -i $ENV{HOME}/.ssh/image_transfer /tmp/fwStatusInfo  ${scpTarget}");
	}
      }

      $cmsShow_cnt++;
      $live_cnt++;
      $feeder_cnt++;
      $img_cnt++;

      sleep 1;
    }
  }
}
