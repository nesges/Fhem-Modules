########################################################################
# 98_FireTV.pm
#
# Control a FireTV-Device from FHEM
# 
# Prerequisites:
#   1.) enable adb debugging in your fire tv
#   2.) get adb and copy the binary to /usr/bin/
#       some sources for raspbian binaries:
#           https://github.com/DeepSilence/adb-arm
#           https://forum.xda-developers.com/showthread.php?t=1924492
#           http://forum.xda-developers.com/attachment.php?attachmentid=1392336&d=1349930509
#
# uses 73_PRESENCE.pm by Markus Bloch
# uses File::MimeInfo by Michiel Beijen
#
# 2017 by Thomas Nesges <thomas@nesges.eu>
# $Id$
########################################################################

package main;

use strict;
use warnings;
use Time::HiRes;
use POSIX qw(tmpnam);
use File::Temp qw(tempdir);

sub FireTV_Initialize($);
sub FireTV_Define($$);
sub FireTV_Undef($$);
sub FireTV_Set($@);
sub FireTV_Get($@);
sub FireTV_Attr(@);
sub FireTV_Notify($$);

sub FireTV_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}      = 'FireTV_Define';
    $hash->{UndefFn}    = 'FireTV_Undef';
    $hash->{SetFn}      = 'FireTV_Set';
    $hash->{GetFn}      = 'FireTV_Get';
    $hash->{AttrFn}     = 'FireTV_Attr';
    $hash->{AttrList}   = "holdconnection:yes,no screenshotpath upviewdeleteafter uploaddeleteafter ".$readingFnAttributes;
    
    if(LoadModule("PRESENCE") eq "PRESENCE") {    
        # PRESENCE    
        $hash->{ReadFn}     = "PRESENCE_Read";  
        $hash->{ReadyFn}    = "PRESENCE_Ready";
        $hash->{NotifyFn}   = "FireTV_Notify";
        $hash->{AttrList}  .= " ping_count:1,2,3,4,5,6,7,8,9,10"
                                ." absenceThreshold:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20"
                                ." presenceThreshold:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20"
                                ." absenceTimeout presenceTimeout "
                                ." do_not_notify:0,1 disable:0,1 disabledForIntervals "; # disabledForIntervals seems to be broken - TODO
    }
}

sub FireTV_Define($$) {
    my ($hash, $def) = @_;
    my @param = split('[ \t]+', $def);
    
    my $name = $param[0];
    
    if(LoadModule("PRESENCE") eq "PRESENCE") {
        $hash->{helper}{$name}{'PRESENCE_loaded'} = 1;
    } else {
        Log3 $name, 3, "[$name] FireTV_Initialize WARNING: couldn't load module PRESENCE";
        $hash->{helper}{$name}{'PRESENCE_loaded'} = 0;       
    }
    
    if(int(@param) < 3) {
        if($hash->{helper}{$name}{'PRESENCE_loaded'}) {
            return "too few parameters: define <name> FireTV <IP> [<ADB_PATH>] [<PRESENCE_TIMEOUT_ABSENT>] [<PRESENCE_TIMEOUT_PRESENT>] [<PRESENCE_MODE>] [<PRESENCE_ADDRESS>]";
        } else {
            return "too few parameters: define <name> FireTV <IP> [<ADB_PATH>]";
        }
    }
    
    if(defined($param[2]) && $param[2]!~/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
        return "IP '".$param[3]."' is no valid ip address";
    }
    if(defined($param[3]) && ! -x $param[3]) {
        return "ADB_PATH '".$param[3]."' is not executable";
    }
    if(defined($param[4]) && $param[4]!~/^\d+$/) {
        return "PRESENCE_TIMEOUT_ABSENT '".$param[3]."' is no valid integer number";
    }
    if(defined($param[5]) && $param[5]!~/^\d+$/) {
        return "PRESENCE_TIMEOUT_PRESENT '".$param[3]."' is no valid integer number";
    }
    if(defined($param[6]) && $param[6]!~/^(lan-ping|lan-bluetooth|local-bluetooth|fritzbox|shellscript|function|event)$/) {
        return "PRESENCE_MODE '".$param[3]."' must be one of lan-ping, lan-bluetooth, local-bluetooth, fritzbox, shellscript, function or event";
    }
    
    $hash->{NAME}       = $name;
    $hash->{IP}         = $param[2];
    $hash->{ADB}        = $param[3] || '/usr/bin/adb';
    $hash->{ADBVERSION} = `$hash->{ADB} version 2>&1` || $!;
    $hash->{STATE}      = 'defined';
    $hash->{VERSION}    = '0.4';
    
    if($hash->{helper}{$name}{'PRESENCE_loaded'}) {
        # PRESENCE
        $hash->{NOTIFYDEV}          = "global,$name";
        $hash->{TIMEOUT_NORMAL}     = $param[4] || 30;
        $hash->{TIMEOUT_PRESENT}    = $param[5] || $hash->{TIMEOUT_NORMAL};
        $hash->{MODE}               = $param[6] || 'lan-ping';
        $hash->{ADDRESS}            = $param[7] || $hash->{IP};
        
        PRESENCE_StartLocalScan($hash, 1);
    }

    FireTV_Get($hash, $name, 'packages');
    return undef;
}

sub FireTV_Undef($$) {
    my ($hash, $arg) = @_; 
    
    my $name = $hash->{NAME};
    
    RemoveInternalTimer($hash);
    # PRESENCE
    if(defined($hash->{helper}{RUNNING_PID})) {
        BlockingKill($hash->{helper}{RUNNING_PID});
    }
    # own
    if(defined($hash->{helper}{$name}{'blockingcall'})) {
        foreach my $blockingcall (keys($hash->{helper}{$name}{'blockingcall'})) {
            BlockingKill($blockingcall->{RUNNING_PID});
        }
    }
    DevIo_CloseDev($hash); 

    return undef;
}

sub FireTV_Get($@) {
	my ($hash, @param) = @_;
	
	return '"get FireTV" needs at least one argument' if (int(@param) < 2);
	
	my $name = shift @param;
	my $opt = shift @param;
	my $value = join(" ", @param);
	
	if(! FireTV_connect($hash)) {
        return "error: ".$hash->{helper}{$name}{'lastadbresponse'};
    }
	
	if($opt eq 'packages') {
	    if(FireTV_adb($hash, 'shell pm list packages -f -3')) {
	        my @response = split(/[\n\r]+/, $hash->{helper}{$name}{'lastadbresponse'});
	        my @apk;
	        foreach my $line (@response) {
	            my ($package, $apk) = split('=', $line);
	            push @apk, $apk;
	        }
	        @apk = sort(@apk);
	        $hash->{helper}{$name}{'packages'} = join(',', @apk);
	        return "Found the following installed packages: \n\n".join("\n", @apk);
	    } else {
	        return "error: ".$hash->{helper}{$name}{'lastadbresponse'};
	    }

	} elsif($opt eq 'isapprunning') {
        return FireTV_is_app_running($hash, $value);

    } elsif($opt eq 'adb') {
	    if(FireTV_adb($hash, $value)) {
	        my @response = split(/[\n\r]+/, $hash->{helper}{$name}{'lastadbresponse'});
	        return join("\n", @response);
	    } else {
	        return "error: ".$hash->{helper}{$name}{'lastadbresponse'};
	    }

	} else {
	    return "Unknown argument $opt, choose one of packages:noArg isapprunning:".$hash->{helper}{$name}{'packages'}." adb ";
	}
	return undef;
}

sub FireTV_Set($@) {
	my ($hash, @param) = @_;
	
	return '"set FireTV" needs at least one argument' if (int(@param) < 2);
	
	my $name = shift @param;
	my $opt = shift @param;
	my $value = join(" ", @param);
	my $response = undef;
	
	if($opt =~ /^(appstart|appstop|apptoggle|button|screen|window|search|upload|uploadandview|view|deletefile|install|adb|screenshot)$/) {
	    # $opt that need an adb-connection
	    if(FireTV_connect($hash)) {
	        if($opt eq 'appstart') {
	            $response = FireTV_app($hash, $value, 'start');
	        } elsif($opt eq 'appstop') {
	            $response = FireTV_app($hash, $value, 'stop');
            } elsif($opt eq 'apptoggle') {
	            if(FireTV_is_app_running($hash, $value)) {
	                $response = FireTV_app($hash, $value, 'stop');
	            } else {
	                $response = FireTV_app($hash, $value, 'start');
	            }
            
            } elsif($opt eq 'button') {
	            if($value eq 'up') {
	                $response = FireTV_up($hash);
	            } elsif($value eq 'down') {
	                $response = FireTV_down($hash);
	            } elsif($value eq 'left') {
	                $response = FireTV_left($hash);
	            } elsif($value eq 'right') {
	                $response = FireTV_right($hash);
	            } elsif($value eq 'enter') {
	                $response = FireTV_enter($hash);
	            } elsif($value eq 'back') {
	                $response = FireTV_back($hash);
	            } elsif($value eq 'home') {
	                $response = FireTV_home($hash);
	            } elsif($value eq 'menu') {
	                $response = FireTV_menu($hash);
	            } elsif($value eq 'prev') {
	                $response = FireTV_playpause($hash);
	            } elsif($value eq 'playpause') {
	                $response = FireTV_enter($hash);
	            } elsif($value eq 'next') {
	                $response = FireTV_next($hash);
	            }	        

	        } elsif($opt eq 'screen') {
	            if($value eq 'wakeup') {
	                $response = FireTV_wakeup($hash);
	            } elsif($value eq 'toggle') {
	                $response = FireTV_power($hash);
	            } elsif($value eq 'sleep') {
	                $response = FireTV_sleep($hash);
	            }
            
            } elsif($opt eq 'screenshot') {
	            # check if an internal timer is already running
	            my $pid=0;
	            if(exists($hash->{helper}{$name}{'blockingcall'}{'screenshot'}{RUNNING_PID})) {
	                $pid = $hash->{helper}{$name}{'blockingcall'}{'screenshot'}{RUNNING_PID};
	                if($pid && !kill 0, $pid) {
	                    Log3 $name, 4, "[$name] FireTV_Set screenshot: killing blockingcall $pid";
	                    delete($hash->{helper}{$name}{'blockingcall'}{'screenshot'}{RUNNING_PID});
	                    $pid=0;
	                }
	            }
	            if(!$pid) {
	                $hash->{helper}{$name}{'blockingcall'}{'screenshot'}{RUNNING_PID} = BlockingCall('FireTV_screenshot', $name, 'FireTV_screenshot_ok', 300, 'FireTV_screenshot_error', $name);
	                return undef;
	            } else {
	                return "screenshot already running ($pid)";
	            }
	    
            } elsif($opt eq 'window') {
                if($value eq 'settings') {
	                $response = FireTV_settings($hash);
                } elsif($value eq 'appsettings') {
	                $response = FireTV_appsettings($hash);
                } elsif($value eq 'fotos') {
	                $response = FireTV_app($hash, 'com.amazon.bueller.photos', 'start');
                } elsif($value eq 'music') {
	                $response = FireTV_app($hash, 'com.amazon.bueller.music', 'start');
                }
        
            } elsif($opt eq 'search') {
	            $response = FireTV_search($hash, $value);
            } elsif($opt eq 'searchonly') {
	            $response = FireTV_search_only($hash, $value);
            } elsif($opt eq 'text') {
	            $response = FireTV_text($hash, $value);
	        
	        
	        } elsif($opt eq 'upload') {
	            my ($remotefile,$contenttype) = split(":", FireTV_uploadfile($hash, $value));
	            if($remotefile) {
                    $response = "$remotefile:$contenttype";
                    # internal timer to delete the uploaded file
                    if(defined($attr{$name}{uploaddeleteafter}) && $attr{$name}{uploaddeleteafter} >= 0) {
                        # check if an internal timer is already running
                        my $pid=0;
	                    if(exists($hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID})) {
	                        $pid = $hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID};
	                        if($pid && !kill 0, $pid) {
	                            Log3 $name, 4, "[$name] FireTV_Set upload: killing blockingcall $pid";
	                            delete($hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID});
	                            $pid=0;
	                        }
	                    }
                        if(!$pid) {
                            my $param = "$name|$remotefile|".$attr{$name}{uploaddeleteafter};
                            Log3 $name, 4, "[$name] FireTV_Set upload: starting blockingcall to delete remotefile $remotefile in ".$attr{$name}{uploaddeleteafter}." seconds";
                            $hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID} = BlockingCall('FireTV_deletefile_blocking', $param, 'FireTV_deletefile_blocking_ok', $attr{$name}{uploaddeleteafter}+30, 'FireTV_deletefile_blocking_error', $param);
                        } else {
                            Log3 $name, 4, "[$name] FireTV_Set upload: blockingcall to delete remotefile $remotefile already running ($pid)";
                        }
                    }
                } else {
	                return "error while uploading localfile $value";
	            }

	        } elsif($opt eq 'view') {
	            my ($remotefile,$contenttype) = split(/\ |:/, $value);
	            if(! $contenttype) {
	                return "please specifiy the files contenttype, e.g: $remotefile image/png"
                }
	            if(FireTV_wakeup($hash)) {
                    $response = FireTV_view($hash, $remotefile, $contenttype);
                }

	        } elsif($opt eq 'uploadandview') {
	            my ($remotefile,$contenttype) = split(":", FireTV_uploadfile($hash, $value));
	            if($remotefile) {
	                if(FireTV_wakeup($hash)) {
	                    $response = FireTV_view($hash, $remotefile, $contenttype);
	                }
	                
	                # internal timer to delete the uploaded file                
                    if(defined($attr{$name}{upviewdeleteafter}) && $attr{$name}{upviewdeleteafter} >= 0) {
                        my $pid=0;
	                    if(exists($hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID})) {
	                        $pid = $hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID};
	                        if($pid && !kill 0, $pid) {
	                            Log3 $name, 4, "[$name] FireTV_Set uploadandview: killing blockingcall $pid";
	                            delete($hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID});
	                            $pid=0;
	                        }
	                    }
                        if(!$pid) {
                            my $param = "$name|$remotefile|".$attr{$name}{upviewdeleteafter};
                            Log3 $name, 4, "[$name] FireTV_Set uploadandview: starting blockingcall to delete remotefile $remotefile in ".$attr{$name}{upviewdeleteafter}." seconds";
                            $hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID} = BlockingCall('FireTV_deletefile_blocking', $param, 'FireTV_deletefile_blocking_ok', $attr{$name}{upviewdeleteafter}+30, 'FireTV_deletefile_blocking_error', $param);
                        } else {
                            Log3 $name, 4, "[$name] FireTV_Set uploadandview: blockingcall to delete remotefile $remotefile already running ($pid)";
                        }
                    }
	            } else {
	                return "error while uploading localfile $value";
	            }
	        
	        } elsif($opt eq 'deletefile') {
                return FireTV_deletefile($hash, $value);
            
            } elsif($opt eq 'install') {
	            # implemented as blocking call
	            # there should be no need to implement this nonblocking, since apk installation is usually something you oversee
	            $response = FireTV_adb($hash, "install -r $value");
            
            } elsif($opt eq 'adb') {
	            $response = FireTV_adb($hash, $value);
            }
        }
	} elsif($opt =~ /^(connect|disconnect|statusRequest)$/) {
	    if($opt eq 'connect') {
	        $response = FireTV_connect($hash);
        } elsif($opt eq 'disconnect') {
	        $response = FireTV_connect($hash, 'disconnect');
	    
	    # PRESENCE
	    } elsif($opt eq 'statusRequest' && $hash->{helper}{$name}{'PRESENCE_loaded'}) {
            if($hash->{MODE} ne "lan-bluetooth") {
                Log3 $name, 4, "[$name] FireTV_Attr: starting local scan";
                return PRESENCE_StartLocalScan($hash, 1);
            } else {
                if(exists($hash->{FD})) {
                    DevIo_SimpleWrite($hash, "now\n", 2);
                } else {
                    return "FireTV_Attr Definition '$name' is not connected to ".$hash->{DeviceName}; 
                }
            } 
        }
        
	} else {
		my $packages = $hash->{helper}{$name}{'packages'};
	    
	    my @buttons = sort(qw(up down left right enter back home menu prev playpause next));
	    my @keys = sort(qw(KEYCODE_DPAD_UP KEYCODE_DPAD_DOWN KEYCODE_DPAD_LEFT KEYCODE_DPAD_CENTER 
	        KEYCODE_DPAD_RIGHT KEYCODE_BACK KEYCODE_HOME KEYCODE_MENU KEYCODE_MEDIA_PREVIOUS 
	        KEYCODE_MEDIA_PLAY_PAUSE KEYCODE_MEDIA_FAST_FORWARD KEYCODE_WAKEUP KEYCODE_POWER));
        my @windows = sort(qw(appsettings settings fotos music));
	    
	    my @presence;
	    if($hash->{helper}{$name}{'PRESENCE_loaded'}) {
	        push @presence, 'statusRequest:noArg';
	    }
	    
		return "Unknown argument $opt choose one of "
		    ."appstart:".$packages." appstop:".$packages." apptoggle:".$packages." "
            ."connect:noArg disconnect:noArg screen:sleep,toggle,wakeup screenshot:noArg "
            ."search searchonly text upload uploadandview view deletefile install adb "
		    ."key:".join(',', @keys)." "
		    ."button:".join(',', @buttons)." "
		    ."window:".join(',', @windows)." "
		    .join(',', @presence)." ";
	}

    if(!$response) {
	    $response = "error: ".$hash->{helper}{$name}{'lastadbresponse'};
    }
	return $response eq "1"?undef:$response;
}

sub FireTV_Attr(@) {
	my ($cmd,$name,$attr_name,$attr_value) = @_;
	
    my $hash = $defs{$name};
	
	if($cmd eq "set") {
	    my $err;

        if($attr_name eq "holdconnection") {
            if($attr_value !~ /^yes|no$/) {
			    $err = "Invalid argument $attr_value to $attr_name. Must be yes or no.";
	        }
		
		} elsif($attr_name =~ /^upviewdeleteafter|uploaddeleteafter$/) {
            if($attr_value !~ /^\d*$/) {
			    $err = "Invalid argument $attr_value to $attr_name. Must be a valid integer number.";
	        }
		
		} elsif($attr_name eq "screenshotpath") {
		    my $basename = $attr_value;
		    if(-d $basename ) {
		        if($basename !~ /\/$/) {
		            $basename .= '/';
		        }
		    } else {
		        $basename =~ s|(.*/).*|$1|; 
		    }
		    if(! -w $basename) {
		        $err = "$basename is not writeable";
		    }
		
		} elsif($attr_name =~ "/^(absenceThreshold|presenceThreshold|ping_count)$/") {
            if($attr_value !~ /^\d+$/) {
                $err = "$attr_name must be a valid integer number";
            }
            if($hash->{MODE} eq "event") {
                $err = "$attr_name is not applicable for mode 'event'";
            }
		
		} elsif($attr_name =~ "/^(absenceTimeout|presenceTimeout)$/") {
            if($attr_value !~ /^\d?\d(?::\d\d){0,2}$/) {
                $err = "$attr_value is not a valid time frame value. See commandref on PRESENCE for the correct syntax" ;
            }
            if($hash->{MODE} ne "event") {
                $err = "$attr_name is only applicable for mode 'event'";
            }
		
		} elsif($attr_name eq "disable") {
		    if($attr_value) {
		        $hash->{STATE} = 'disabled';
		        RemoveInternalTimer($hash);
		    } else {
		        $hash->{STATE} = 'defined';
		        PRESENCE_StartLocalScan($hash, 1);
		    }
		    readingsSingleUpdate($hash, "state", $hash->{STATE}, 1);
		}

        if($err) {
            Log3 $name, 3, "[$name] FireTV_Attr ERROR: $err";
			return $err;
		}
    }
	return undef;
}

sub FireTV_Notify($$) {
    my ($hash,$dev) = @_;
    my $name = $hash->{NAME};
    my $dev_name = $dev->{NAME};
    
    return undef if(!defined($hash) or !defined($dev));
    return undef if(!defined($dev_name) or !defined($name));
    
    my $events = deviceEvents($dev,0);
    
    if($hash->{helper}{$name}{'PRESENCE_loaded'}) {
        # reread packages on state change from absent to present
        if($dev_name eq $name) {
            foreach my $event (@{$events}) {
                if($event eq 'present' && OldValue($name) eq 'absent') {
                    Log3 $name, 4, "[$name] FireTV_Notify: changed state from absent to present; reread packages";
                    FireTV_Get($hash, $name, 'packages');
                }
            }
        } else {
            return PRESENCE_Notify($hash, $dev);
        }
    }
    return;
}


# wrapper for the adb command
sub FireTV_adb($$) {
    my $hash = shift;
    my $cmd = shift;
    
    if(ref $hash ne 'HASH' ) {
        $hash = $defs{$hash};
    }
    my $name = $hash->{NAME};
    my $ip = $hash->{IP};
    
    # connect if not connected
    # don't rely on that! 
    # always call FireTV_connect before issuing commands, to make sure that 
    # an old/broken connection is reset first
    if($cmd !~ /^(?:dis)?connect/) {
        if(!$hash->{adbconnected}) {
            FireTV_connect($hash);
        }
    }
    
    if($hash->{adbconnected} || $cmd =~ /^connect/ ) {
        $hash->{helper}{$name}{lastadbcmd} = $hash->{ADB}." $cmd";
        Log3 $name, 4, "[$name] FireTV_adb command: ".$hash->{helper}{$name}{lastadbcmd};

        # execute command
        $hash->{helper}{$name}{lastadbresponse} = `$hash->{helper}{$name}{lastadbcmd} 2>&1` || '';
        
        # check if adb server needs a restart
        if($hash->{helper}{$name}{lastadbresponse} =~ /cannot bind 'tcp:5037'/) {
            Log3 $name, 4, "[$name] FireTV_adb response: ".$hash->{helper}{$name}{lastadbresponse};
            Log3 $name, 4, "[$name] FireTV_adb: restarting adb server and repeating last command";
            system($hash->{ADB}." kill-server");
            system($hash->{ADB}." start-server");
            system($hash->{ADB}." connect ".$hash->{IP});
            $hash->{helper}{$name}{lastadbresponse} = `$hash->{helper}{$name}{lastadbcmd} 2>&1` || '';
        }
        
        $hash->{helper}{$name}{lastadbresponse} =~ s/^\s*//sg;
        $hash->{helper}{$name}{lastadbresponse} =~ s/\s*$//sg;

        Log3 $name, 4, "[$name] FireTV_adb response: ".$hash->{helper}{$name}{lastadbresponse} if $hash->{helper}{$name}{lastadbresponse};
        return 1;
    } else {
        Log3 $name, 4, "[$name] FireTV_adb not connected: ".$hash->{helper}{$name}{lastadbresponse};
    }
    return undef;
}

# connect/disconnect adb to your device
sub FireTV_connect($;$) {
    my $hash = shift;
    my $action = shift || 'connect';

    if(ref $hash ne 'HASH' ) {
        $hash = $defs{$hash};
    }
    my $name = $hash->{NAME};
    my $ip = $hash->{IP};

    # if marked as connected, disconnect first
    if($action eq 'connect' && $hash->{adbconnected}) {
        if(!defined($attr{$name}{holdconnection}) || $attr{$name}{holdconnection} ne 'yes') {
            system($hash->{ADB}." disconnect ".$hash->{IP});
            # FireTV_adb($hash, "disconnect $ip");
        } else {
            Log3 $name, 4, "[$name] FireTV_connect: no disconnect because of holdconnection yes";
        }
    }
    
    # connect/disconnect
    if(FireTV_adb($hash, "$action $ip")) {
        if($action eq 'disconnect') {
            Log3 $name, 4, "[$name] FireTV_connect (disconnect): ".$hash->{helper}{$name}{lastadbresponse};
            $hash->{adbconnected} = 0;
            return 1;
        } elsif($action eq 'connect' && $hash->{helper}{$name}{lastadbresponse} =~ 'unable to connect') {
            Log3 $name, 4, "[$name] FireTV_connect (connect): ".$hash->{helper}{$name}{lastadbresponse};
            $hash->{adbconnected} = 0;
        } else {
            Log3 $name, 4, "[$name] FireTV_connect (connect): ".$hash->{helper}{$name}{lastadbresponse};
            $hash->{adbconnected} = 1;
        }
        return $hash->{adbconnected};
    }
    return undef;
}

# send a single keyevent
sub FireTV_key($$) {
    my $hash = shift;
    my $key = shift;
    
    return FireTV_adb($hash, "shell input keyevent $key");
}

# send a text
sub FireTV_text($;$) {
    my $hash = shift;
    my $text = shift;
    $text =~ s/ /%s/g;
    
    return FireTV_adb($hash, "shell input text $text");
}


# fire remote buttons
sub FireTV_up($) {
    return FireTV_key(shift, "KEYCODE_DPAD_UP");
}
sub FireTV_down($) {
    return FireTV_key(shift, "KEYCODE_DPAD_DOWN");
}
sub FireTV_left($) {
    return FireTV_key(shift, "KEYCODE_DPAD_LEFT");
}
sub FireTV_enter($) {
    return FireTV_key(shift, "KEYCODE_DPAD_CENTER");
}
sub FireTV_right($) {
    return FireTV_key(shift, "KEYCODE_DPAD_RIGHT");
}
sub FireTV_back($) {
    return FireTV_key(shift, "KEYCODE_BACK");
}
sub FireTV_home($) {
    return FireTV_key(shift, "KEYCODE_HOME");
}
sub FireTV_menu($) {
    return FireTV_key(shift, "KEYCODE_MENU");
}
sub FireTV_prev($) {
    return FireTV_key(shift, "KEYCODE_MEDIA_PREVIOUS");
}
sub FireTV_playpause($) {
    return FireTV_key(shift, "KEYCODE_MEDIA_PLAY_PAUSE");
}
sub FireTV_next($) {
    return FireTV_key(shift, "KEYCODE_MEDIA_FAST_FORWARD");
}

sub FireTV_wakeup($) {
    # wakeup from daydream
    return FireTV_key(shift, "KEYCODE_WAKEUP");
}
sub FireTV_power($) {
    # press power button -> go to sleep or wakeup
    return FireTV_key(shift, "KEYCODE_POWER");
}
sub FireTV_sleep($) {
    my $hash = shift;
    if(FireTV_key($hash, "KEYCODE_WAKEUP")) {
        usleep(10000);
        return FireTV_key($hash, "KEYCODE_POWER");
    }
    return undef;
}


# complex actions

# navigate to global search, enter some text and navigate to the first result
sub FireTV_search($$) {
    my $hash = shift;
    my $text = shift;
    
    if($text) {
        if(FireTV_search_only($hash,$text) && FireTV_down($hash) && FireTV_enter($hash)) {
            return 1;
        }
    }
    return undef;
}

sub FireTV_search_only($$) {
    my $hash = shift;
    my $text = shift;
    
    # may need some fine tuning
    if(FireTV_wakeup($hash)) {
        usleep(10000);
        if(FireTV_home($hash)) {
            usleep(500);
            if(FireTV_home($hash)) {
                if(FireTV_up($hash)) {
                    if(FireTV_enter($hash)) {
                        if($text) {
                            if(FireTV_text($hash,$text)) {
                                return FireTV_next($hash);
                            }
                        }
                    }
                }
            }
        }
    }
    return undef;
}

# navigate to system settings
sub FireTV_settings($) {
    my $hash = shift;
    if(FireTV_wakeup($hash)) {
        usleep(10000);
        return FireTV_adb($hash, "shell am start -n com.amazon.tv.launcher/.ui.SettingsActivity");
    }
    return undef;
}

# navigate to system settings -> installed apps
sub FireTV_appsettings($) {
    my $hash = shift;
    if(FireTV_wakeup($hash)) {
        usleep(10000);
        return FireTV_adb($hash, "shell am start -n com.amazon.tv.settings/.tv.AllApplicationsSettingsActivity");
    }
    return undef;
}

sub FireTV_app($$;$) {
    my $hash = shift;
    my $app = shift;
    my $action = shift || 'start';
    my $name = $hash->{NAME};
    
    if(FireTV_wakeup($hash)) {
        if($action eq 'start') {
            if(FireTV_adb($hash, "shell monkey -p $app -c android.intent.category.LAUNCHER 1")) {
                my $response = $hash->{helper}{$name}{lastadbresponse};
                if($response !~ /No activities found to run, monkey aborted/i) {
                    return $app.' started';
                } else {
                    return "error: ".$response;
                }
            }
        } elsif($action eq 'stop') {
            if(FireTV_adb($hash, "shell am force-stop $app")) {
                return $app.' stopped';
            }
        }
    }
    return undef;
}

sub FireTV_is_app_running($$) {
    my $hash = shift;
    my $app = shift;
    
    my $name = $hash->{NAME};
    
    if(FireTV_adb($hash, 'shell ps|grep '.$app)) {
        my $adb = $hash->{helper}{$name}{lastadbresponse};
        if($adb =~ /(.+?)\s+(\d+)\s+.*$app/) {
            my $pid = $2;
            return $pid;
        }
        return 0;
    }
    return undef;
}

sub FireTV_rndnam($) {
    return shift
        .chr(97+rand(24))
        .chr(97+rand(24))
        .chr(97+rand(24))
        .chr(97+rand(24))
        .chr(97+rand(24))
        .chr(97+rand(24))
        .int(rand(8999)+1000);
}

sub FireTV_tempfile($;$$$) {
    my $hash = shift;
    my $prefix = shift || '/sdcard/';
    my $suffix = shift || '';
    my $maxtries = shift || 5000;

    my $name = $hash->{NAME};

    my $c=0;
    my $tempfile = FireTV_rndnam($prefix).$suffix;
    until(FireTV_adb($hash, "shell ls $tempfile") && $hash->{helper}{$name}{lastadbresponse} =~ /no such file or directory/i) {
        $tempfile = FireTV_rndnam($prefix).$suffix;
        return undef if(++$c>$maxtries);
    }
    if(! FireTV_adb($hash, "shell touch $tempfile")) {
        Log3 $name, 3, "[$name] FireTV_tempfile: couldn't touch tempfile ".$tempfile;
    }
    return $tempfile;
}

sub FireTV_localtempfile($;$$$) {
    my $hash = shift;
    my $prefix = shift || tempdir( CLEANUP=>1 );
    my $suffix = shift || '';
    my $maxtries = shift || 5000;

    my $name = $hash->{NAME};

    if($prefix !~ /\/$/) {
        $prefix .= '/';
    }

    my $c=0;
    my $tempfile = FireTV_rndnam($prefix).$suffix;
    until(! -e $tempfile) {
        $tempfile = FireTV_rndnam($prefix).$suffix;
        return undef if(++$c>$maxtries);
    }
    if(open my $fh, ">>", $tempfile) {
        Log3 $name, 4, "[$name] FireTV_localtempfile tempfile: ".$tempfile;
        close $fh;
        return $tempfile;
    }
    return undef;
}

sub FireTV_screenshot($) {
    my $hash = shift;
    if(ref $hash ne 'HASH' ) {
        $hash = $defs{$hash};
    }
    my $name = $hash->{NAME};
    
    if(FireTV_connect($hash)) {
	    if(FireTV_wakeup($hash)) {
            my $remote_tempfile = FireTV_tempfile($hash, '/sdcard/screenshot');
            if(FireTV_adb($hash, "shell screencap -p $remote_tempfile")) {
                my $localfile;
                if(!defined($attr{$name}{screenshotpath})) {
                    $localfile = tmpnam();
                } elsif(-d $attr{$name}{screenshotpath}) {
                    $localfile = FireTV_localtempfile($hash, $attr{$name}{screenshotpath}, '.png')
                } else {
                    $localfile = $attr{$name}{screenshotpath};
                }
                
                if($localfile) {
                    FireTV_adb($hash, "pull $remote_tempfile $localfile");
                    if(! -e $localfile) {
                        Log3 $name, 3, "[$name] FireTV_screenshot: couldn't pull to localfile $localfile (".$hash->{helper}{$name}{lastadbresponse}.")";
                    }
                } else {
                    Log3 $name, 3, "[$name] FireTV_screenshot: couldn't create localfile (".$hash->{helper}{$name}{lastadbresponse}.")";
                }
                if(! FireTV_adb($hash, "shell rm $remote_tempfile")) {
                    Log3 $name, 3, "[$name] FireTV_screenshot: couldn't delete remote tempfile $remote_tempfile";
                }
                
                return "$name|$localfile";
            }
        }
    }
    return undef;
}

sub FireTV_deletefile($$) {
    my $hash = shift;
    my $remotefile = shift;
    if(ref $hash ne 'HASH' ) {
        $hash = $defs{$hash};
    }
    my $name = $hash->{NAME};
       
    # only allow to delete files that this device has uploaded
    # uploaded files are memorized in internalval uploadedfiles
    $remotefile =~ s/:.*//;
    my @uploadedfiles = split(/,\ */, $hash->{uploadedfiles});
    if(grep {$_ =~ /^$remotefile:/ } @uploadedfiles) {
        @uploadedfiles = grep { $_ !~ /^$remotefile:/ } @uploadedfiles;
        $hash->{uploadedfiles} = join ', ', @uploadedfiles;
        my $response = FireTV_adb($hash, "shell rm $remotefile");
        Log3 $name, 4, "[$name] FireTV_deletefile: deletefile $remotefile: $response";
        return $response;
    } else {
        if($remotefile eq '--all') {
            Log3 $name, 4, "[$name] FireTV_deletefile: deletefile --all";
            if(@uploadedfiles > 0) {
                my @deleted;
                foreach my $ufile (@uploadedfiles) {
                    my ($file, $type) = split(/:/, $ufile);
                    if(FireTV_adb($hash, "shell rm $file")) {
                        Log3 $name, 4, "[$name] FireTV_deletefile: deleted file $file";
                        my @u = split(/,\ */, $hash->{uploadedfiles});
                        @u = grep { $_ !~ /^$file:/ } @u;
                        $hash->{uploadedfiles} = join ', ', @u;
                        push @deleted, $file;
                    }
                }
                return "deleted all uploaded files: ".join("\n", @deleted);
            } else {
                Log3 $name, 4, "[$name] FireTV_deletefile: no uploaded files to delete";
                return "no uploaded files to delete";
            }
        }
        return "$remotefile wasn't uploaded by this device, so I reject deleting it";
    }
}

sub FireTV_deletefile_blocking($) {
    my @param = split(/\|/, shift);
    my $name = $param[0];
    my $remotefile = $param[1];
    my $delay = $param[2] || 0;
    my $hash = $defs{$name};
    
    if($remotefile ne '--all') {
        sleep($delay);
        return "$name|$remotefile|".FireTV_deletefile($hash, $remotefile);
    } else {
        Log3 $name, 3, "[$name] FireTV_deletefile_blocking: --all is not allowed here";
    }
}

sub FireTV_deletefile_blocking_ok($) {
    my @param = split(/\|/, shift);
    my $name = $param[0];
    my $remotefile = $param[1];
    my $response = $param[2];
    my $hash = $defs{$name};
    
    Log3 $name, 4, "[$name] FireTV_deletefile_blocking_ok: $response";

    # delete the file from uploadedfiles
    # FireTV_deletefile does this, but it's lost in the fork
    my @uploadedfiles = split(/,\ */, $hash->{uploadedfiles});
    @uploadedfiles = grep { $_ !~ /^$remotefile:/ } @uploadedfiles;
    $hash->{uploadedfiles} = join ', ', @uploadedfiles;

    delete($hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID});
}

sub FireTV_deletefile_blocking_error($) {
    my @param = split(/\|/, shift);
    my $name = $param[0];
    my $remotefile = $param[1];
    my $delay = $param[2] || 0;
    my $hash = $defs{$name};
    
    Log3 $name, 3, "[$name] FireTV_deletefile_blocking_error: $name";
    delete($hash->{helper}{$name}{'blockingcall'}{'deletefile_'.$remotefile}{RUNNING_PID});
}


sub FireTV_screenshot_ok($) {
    my @param = split(/\|/, shift);
    my $name = $param[0];
    my $localfile = $param[1];
    
    my $hash = $defs{$name};
    
    if(-r $localfile && -s $localfile) {
        Log3 $name, 4, "[$name] FireTV_screenshot_ok: $localfile";
        readingsSingleUpdate($hash, "screenshot", $localfile, 1);
    } else {
        readingsSingleUpdate($hash, "screenshot", '', 1);
        my $details = '';
        if(!-e $localfile) {
            $details =  'file does not exist';
        } elsif(!-r $localfile) {
            $details =  'file ist not readable';
        } elsif(!-s $localfile) {
            $details =  'file ist zero sized';
        }
        Log3 $name, 3, "[$name] FireTV_screenshot_ok: something went wrong when saving $localfile for $name ($details)";
    }
    
    delete($hash->{helper}{$name}{'blockingcall'}{'screenshot'}{RUNNING_PID});
}

sub FireTV_screenshot_error($) {
    my $name = shift;
    my $hash = $defs{$name};
    
    Log3 $name, 3, "[$name] FireTV_screenshot_error: $name";
    readingsSingleUpdate($hash, "screenshot", '', 1);
    delete($hash->{helper}{$name}{'blockingcall'}{'screenshot'}{RUNNING_PID});
}

sub FireTV_uploadfile($$;$$) {
    my $hash = shift;
    if(ref $hash ne 'HASH' ) {
        $hash = $defs{$hash};
    }
    my $name = $hash->{NAME};

    my $localfile = shift;
    my $remotefile = shift || FireTV_tempfile($hash);
    my $contenttype = shift;
  
    if(! -r $localfile) {
        Log3 $name, 3, "[$name] FireTV_uploadfile: can't read localfile $localfile";
        return;
    }  
    
    if(FireTV_adb($hash, "push $localfile $remotefile")) {
        # logic to guess the content-type needs File::MimeInfo
        # content-type is needed for FireTV_view
	    if(! $contenttype) {
	        eval 'use File::MimeInfo "mimetype";1';
	        if($@) {
	            Log3 $name, 3, "[$name] FireTV_uploadfile: please install File::MimeInfo to automatically guess the content-type of uploaded files";
	        } else {
	            $contenttype = mimetype($localfile);
	        }
        }
        
        # memorize uploaded files in internalval uploadedfiles
	    my @uploadedfiles = split(/,\ */, $hash->{uploadedfiles});
	    push @uploadedfiles, "$remotefile:$contenttype";
	    $hash->{uploadedfiles} = join ', ', @uploadedfiles;
        
        return "$remotefile:$contenttype";
    } else {
        Log3 $name, 3, "[$name] FireTV_uploadfile: couldn't upload localfile $localfile to remotefile $remotefile (".$hash->{helper}{$name}{lastadbresponse}.")";
    }
    return undef;
}

sub FireTV_view($$$) {
    my $hash = shift;
    if(ref $hash ne 'HASH' ) {
        $hash = $defs{$hash};
    }
    my $name = $hash->{NAME};
    my $remotefile = shift;
    my $contenttype = shift;

    if($contenttype eq 'load') {
        # download the file to guess it's contenttype - ugly!
        my $localfile = FireTV_localtempfile($hash);
        if(FireTV_adb($hash, "pull $remotefile $localfile")) {
            # logic to guess the content-type needs File::MimeInfo
            eval 'use File::MimeInfo "mimetype";1';
	        if($@) {
	            Log3 $name, 3, "[$name] FireTV_view: please install File::MimeInfo to automatically guess the files content-type";
	        } else {
	            $contenttype = mimetype($localfile);
	        }
	        unlink $localfile;
	    } else {
	        Log3 $name, 3, "[$name] FireTV_view: couldn't download remotefile $remotefile to localfile $localfile (".$hash->{helper}{$name}{lastadbresponse}.")";
	    }
    }
    
    if(! $contenttype) {
        Log3 $name, 3, "[$name] FireTV_view: please specify the files content-type";
        return;
    }

    return FireTV_adb($hash, "shell am start -a android.intent.action.VIEW -d file://$remotefile -t $contenttype");
}

# define FIRETV_REMOTE weblink htmlCode { FireTV_Remote('FIRETV', 'it_remote', 1) }
sub FireTV_Remote($;$$$) {
    my $hash = shift;
    my $remoteicon = shift || 'it_remote';
    my $collapsible = shift || 0;
    my $devicelink = shift;
    
    if(ref $hash ne 'HASH' ) {
        $hash = $defs{$hash};
    }
    my $name = $hash->{NAME};
    if($hash->{TYPE} ne 'FireTV') {
        return "$name is not of type FireTV";
    }
    
    if(defined($devicelink)){
        if($devicelink eq "0") {
            $devicelink="";
        } else {
            $devicelink="<a href='$FW_ME$FW_subdir?detail=$name'>$devicelink</a>";
        }
    } else {
        $devicelink="Remote for <a href='$FW_ME$FW_subdir?detail=$name'>".AttrVal($name, 'alias', $name)."</a>";
    }
    
    my $btncmd = "FW_cmd('$FW_ME$FW_subdir?XHR=1&cmd.$name=set $name button ";
    
    # include html from a user-defined callback "FireTV_Remote_$name_AddButtons"
    my $callbackhtml = "";
    my $callback = "FireTV_Remote_".$name."_AddButtons";
    # this doesn't work as planned: 
    # where should the user implement his callback function? 99_myUtils.pm is too late
    # if someone stumbles upon this and has an idea how to implement a user-callback,
    # please let me know
    #
    # doc:
    # <br>
    # You may define a callback function named <i>FireTV_Remote_&lt;DEVICE&gt;_AddButtons</i> 
    # that returns additional html. It will be called and inserted after the standard buttons. 
    # See the source of contrib/99_Utils_FireTV.pm for an example implementation.
    #
    # perl:
    # no strict 'refs';
    # if(defined &{$callback}) {
    #     $callbackhtml = &{$callback};
    # }
    # use strict 'refs';
    
    my $icon='';
    my $style='';
    if($collapsible) {
        $icon = "<a onClick=\"var toggle='none'; if(jQuery('#$name"."-remote-inner').css('display')==toggle) { toggle='block' }; jQuery('#$name"."-remote-inner').css('display',toggle)\">"
            .FW_makeImage($remoteicon, "expand/collapse", "rc-button")."</a>";
        $style = "style='display:none'";
    } else {
        $icon = FW_makeImage($remoteicon, "Remote", "rc-button");
    }
    
    my $html = "<div class='firetv-remote' id='$name"."-remote'>
        $icon
        $devicelink
        <div id='$name"."-remote-inner' $style>
            <table>
                <tr>
                    <td></td>
                    <td><a onClick=\"$btncmd up')\">".FW_makeImage("rc_UP", "up", "rc-button")."</a></td>
                    <td></td>
                </tr>
                <tr>
                    <td><a onClick=\"$btncmd left')\">".FW_makeImage("rc_LEFT", "left", "rc-button")."</a></td>
                    <td><a onClick=\"$btncmd enter')\">".FW_makeImage("rc_OK", "enter", "rc-button")."</a></td>
                    <td><a onClick=\"$btncmd right')\">".FW_makeImage("rc_RIGHT", "right", "rc-button")."</a></td>
                </tr>
                <tr>
                    <td></td>
                    <td><a onClick=\"$btncmd down')\">".FW_makeImage("rc_DOWN", "down", "rc-button")."</a></td>
                    <td></td>
                </tr>
                <tr>
                    <td><a onClick=\"$btncmd back')\">".FW_makeImage("rc_BACK", "back", "rc-button")."</a></td>
                    <td><a onClick=\"$btncmd home')\">".FW_makeImage("rc_HOME", "home", "rc-button")."</a></td>
                    <td><a onClick=\"$btncmd menu')\">".FW_makeImage("rc_MENU", "menu", "rc-button")."</a></td>
                </tr>
                <tr>
                    <td><a onClick=\"$btncmd prev')\">".FW_makeImage("rc_REW", "prev", "rc-button")."</a></td>
                    <td><a onClick=\"$btncmd playpause')\">".FW_makeImage("rc_PLAY", "playpause", "rc-button")."</a></td>
                    <td><a onClick=\"$btncmd next')\">".FW_makeImage("rc_FF", "next", "rc-button")."</a></td>
                </tr>
                ".$callbackhtml."
            </table>
        </div>
    </div>";

    return $html;
}

# this doesn't work as planned, see above
#
# example for a callback function for FireTV_Remote
# replace FIRETV (sub name and $name) with your devices name
# sub FireTV_Remote_FIRETV_AddButtons() {
#     my $name = 'FIRETV';
#     my $cmd = "FW_cmd('$FW_ME$FW_subdir?XHR=1&cmd.$name=set $name ";
# 
#     return "<tr><td colspan='3'><hr></td></tr>
#             <tr>
#                 <td><a onClick=\"$cmd appstart org.xbmc.kodi')\">".FW_makeImage("kodi", "Kodi", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd appstart com.spotify.tv.android')\">".FW_makeImage("spotify", "Spotify", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd appstart tv.twitch.android.viewer')\">".FW_makeImage("twitch", "twitch", "rc-button")."</a></td>
#             </tr>
#             <tr>
#                 <td><a onClick=\"$cmd screen sleep')\">".FW_makeImage("rc_TV\@red", "sleep", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd screen wakeup')\">".FW_makeImage("rc_TV", "wakeup", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd window settings')\">".FW_makeImage("rc_SETUP", "settings", "rc-button")."</a></td>
#             </tr>
#             <tr>
#                 <td><a onClick=\"$cmd upload /mnt/sky/data/lich_necromancer.png')\">".FW_makeImage("upload", "upload", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd uploadandview /mnt/sky/data/lich_necromancer.png')\">".FW_makeImage("upload\@red", "upload", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd deletefile --all')\">".FW_makeImage("trash", "delete all", "rc-button")."</a></td>
#             </tr>
#             <tr>
#                 <td><a onClick=\"$cmd screenshot')\">".FW_makeImage("image", "screenshot", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd window music')\">".FW_makeImage("music", "music", "rc-button")."</a></td>
#                 <td><a onClick=\"$cmd search terminator')\">".FW_makeImage("robot2", "hasta la vista", "rc-button")."</a></td>
#             </tr>";
# }


1;

=pod
=begin html

<a name="FireTV"></a>
<h3>FireTV</h3>
<ul>
    <i>FireTV</i> is used to remote control a Amazon FireTV device. It is not able 
    to read the currently playing music/movie or other status information, 
    but sending commands to the device. A working copy of <i>adb</i> is needed.
    <br><br>
    <b>Prerequisites</b>
    <ul>
        <li>Activate adb debugging in your fire tv (<a href="http://www.aftvnews.com/how-to-enable-adb-debugging-on-an-amazon-fire-tv-or-fire-tv-stick/">see here</a>)</li>
        <li>Get <i>adb</i> for your fhem-server. Depending on your system, you have several options:
            <ul>
                <li>Win/Mac/Linux: <a href="https://developer.android.com/studio/releases/platform-tools.html">Android SDK Platform-Tools</a></li>
                <li>Raspbian: <a href="https://github.com/DeepSilence/adb-arm">adb-arm</a></li>
            </ul>
        </li>
        <li>uses the perl module <a href="http://search.cpan.org/search?query=File%3A%3AMimeInfo&mode=module">File::MimeInfo</a> for some tasks. Installs via <i>apt-get install libfile-mimeinfo-perl</i> on some systems</li>
        <li>uses 73_PRESENCE.pm by Markus Bloch for presence-detection (included in Fhem by default)</li>
    </ul>
    <br><br>
    <a name="FireTVdefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; FireTV &lt;IP&gt; [&lt;ADB_PATH&gt;] [&lt;PRESENCE_TIMEOUT_ABSENT&gt;] [&lt;PRESENCE_TIMEOUT_PRESENT&gt;] [&lt;PRESENCE_MODE&gt;] [&lt;PRESENCE_ADDRESS&gt;]</code><br>
        <br>
        or, if 73_PRESENCE.pm is not available:<br>
        <br>
        <code>define &lt;name&gt; FireTV &lt;IP&gt; [&lt;ADB_PATH&gt;]</code><br>
        <br>
        Example: <code>define FIRETV FireTV 192.168.178.66 /usr/local/bin/adb</code>
        <br><br>
        <b>IP</b> is the ip-address of your FireTV-device<br>
        <b>ADB_PATH</b> is the full path to your adb-binary. Default: /usr/bin/adb<br>
        <b>PRESENCE_TIMEOUT_ABSENT</b> timeout (in seconds) to the next presence check if the device is absent. Default: 30<br>
        <b>PRESENCE_TIMEOUT_PRESENT</b> timeout (in seconds) to the next presence check if the device is present. Default: &lt;PRESENCE_TIMEOUT_ABSENT&gt;<br>
        <b>PRESENCE_MODE</b> mode for the presence check, see <a href="#PRESENCE">PRESENCE</a>. Default: lan-ping<br>
        <b>PRESENCE_ADRESS</b> address for the presence check, see <a href="#PRESENCE">PRESENCE</a>. Default: &lt;IP&gt;<br>
    </ul>
    <br>
    
    <a name="FireTVget"></a>
    <b>Get</b><br>
    <ul>
        <ul>
            <li><i>adb &lt;COMMAND&gt;</i><br>
                Execute an adb command on your firetv and return it's response. Try <i>adb help</i>.</li>
            <li><i>isapprunning &lt;PACKAGE&gt;</i><br>
                Returns the PID of a running app, or 0 if not running</li>
            <li><i>packages</i><br>
                Reads the list of installed packages on your firetv and stores it internally. <i>get packages</i> is called automatically when the device changes state from absent to present to populate the select-boxes for some other commands (e.g. appstart) in FHEMWEB</li>
        </ul>
    </ul>
    
    <a name="FireTVset"></a>
    <b>Set</b><br>
    <ul>
        <ul>
            <li><i>adb &lt;COMMAND&gt;</i><br>
                Execute an adb command on your firetv. If you need to see the devices response use the <i>get</i> version of this command instead.</li>
            <li><i>appstart &lt;PACKAGE&gt;</i><br>
                Start an app on your firetv. You may read names of installed packages via <i>get packages</i> (see above)</li>
            <li><i>appstop &lt;PACKAGE&gt;</i><br>
                Stop an app on your firetv</li>
            <li><i>apptoggle &lt;PACKAGE&gt;</i><br>
                Start/stop an app on your firetv. Start if not running, stop otherwise</li>
            <li><i>button &lt;BUTTON&gt;</i><br>
                Send a button-press to your firetv. Possible buttons (in order of appearance on a standard fire remote):
                up, left, ok, right, down, back, home, menu, prev, playpause, next</li>
            <li><i>connect</i><br>
                Connect adb to your firetv. This is done automatically by all defined set/get-commands
                </li>
            <li><i>deletefile &lt;PATH&gt;</i><br>
                Delete a file on your firetv. This command is restricted to files, that where uploaded vie <i>upload/uploadandview</i> (see below)</li>
            <li><i>disconnect</i><br>
                Disconnect adb from your firetv</li>
            <li><i>install &lt;APK&gt;</i><br>
                Install ("sideload") an apk-file on your firetv. APK is a local path on your 
                fhem-server. <i>install</i> is implemented as a blocking call, don't use it 
                in scripts</li>
            <li><i>key &lt;KEYCODE&gt;</i><br>
                Send a standard android keycode to your firetv. You can send <a href="https://developer.android.com/reference/android/view/KeyEvent.html">any keycode</a>, 
                but firetv may not understand them all (known to work: KEYCODE_DPAD_UP, 
                KEYCODE_DPAD_DOWN, KEYCODE_DPAD_LEFT, KEYCODE_DPAD_CENTER, KEYCODE_DPAD_RIGHT, 
                KEYCODE_BACK, KEYCODE_HOME, KEYCODE_MENU, KEYCODE_MEDIA_PREVIOUS, 
                KEYCODE_MEDIA_PLAY_PAUSE, KEYCODE_MEDIA_FAST_FORWARD, KEYCODE_WAKEUP, KEYCODE_POWER)</li>
            <li><i>screen &lt;wakeup|toggle|sleep&gt;</i><br>
                Set screen to wake up or sleep or toggle between these states</li>
            <li><i>screenshot</i><br>
                Take a screenshot and download it to a local tempfile on your fhem-server. 
                Since it may take some seconds to produce a screenshot, this function is
                implemented nonblocking (iow: no direct feedback). The path to the local 
                tempfile is saved in a reading "screenshot" and may be set by the attribute 
                "screenshotpath". Screenshots taken while playing a movie/tv-show/etc from 
                amazons library are in general just black. On error the reading "screenshot"
                is emptied</li>
            <li><i>search &lt;TEXT&gt;</i><br>
                Navigate to the search-menu on your firetv, enter text and navigate to the first result</li>
            <li><i>searchonly &lt;TEXT&gt;</i><br>
                Navigate to the search-menu on your firetv and enter text</li>
            <li><i>statusRequest</i><br>
                Schedules an immediate presence-check</li>
            <li><i>text &lt;TEXT&gt;</i><br>
                Send text to your firetv</li>
            <li><i>uploadandview &lt;PATH:CONTENTTYPE&gt;</i><br>
                Upload a file to your firetv and view it on screen. The view action is 
                dependend on an arbitrary installed app that handles CONTENTTYPE and is
                not limited to images. 
                You may omit CONTENTTYPE if you have the perl module File::MimeInfo 
                installed on your system. Such files may be automatically deleted when
                the attribute <i>upviewdeleteafter</i> is set (see below)</li>
            <li><i>upload &lt;PATH&gt;</i><br>
                Upload a file to your firetv. Such files may be automatically deleted 
                when the attribute <i>uploaddeleteafter</i> is set (see below)</li>
            <li><i>view &lt;PATH:CONTENTTYPE&gt;</i><br>
                View a file on your firetv. The view action is dependend on an arbitrary 
                installed app that handles CONTENTTYPE  and is
                not limited to images. If you have the perl module File::MimeInfo installed 
                on your system, you may replace CONTENTTYPE whith the keyword <i>load</i>: 
                The file will be downloaded to your fhem-server prior viewing it on screen, then
                (which may take some time and is generally speaking inefficient).</li>
            <li><i>window &lt;appsetting|fotos|music|settings&gt;</i><br>
                Activate a named window of the firetv menu.</li>
        </ul>
    </ul>
    <br>

    <a name="FireTVattr"></a>
    <b>Attributes</b>
    <ul>
        <ul>
            <li><i>holdconnection</i> yes|no<br>
                "yes" to keep the adb connection open or "no" to close it after every command. Default: no</li>
            <li><i>screenshotpath</i> &lt;PATH&gt;<br>
                If <i>screenshotpath</i> is set to a filename, every new screenshot (see <i>set screenshot</i>) will overwrite that file. 
                If set to a directory, a random file will be created in that directory. 
                If not set, a random file is created in your systems tempdirectory (POSIX tmpnam). Default: not set</li>
            <li><i>uploaddeleteafter</i> &lt;SECONDS&gt;<br>
                Files uploaded via <i>set upload</i> are deleted after SECONDS when set to a positve integer number. Default: not set</li>
            <li><i>upviewdeleteafter</i> &lt;SECONDS&gt;<br>
                Files uploaded via <i>set uploadandview</i> are deleted after SECONDS when set to a positve integer number. Default: not set</li>
        </ul>
        <b>Inherited from <a href='#PRESENCE_attr'>PRESENCE</a>:</b>
        <ul>
            <li><i>absenceThreshold</i></li>
            <li><i>absenceTimeout</i></li>
            <li><i>disable</i></li>
            <li><i>ping_count</i></li>
            <li><i>presenceThreshold</i></li>
            <li><i>presenceTimeout</i></li>
        </ul>
        <b>Other:</b>
        <ul>
            <li><a href='#do_not_notify'>do_not_notify</a></li>
            <li><a href='#readingFnAttributes'>readingFnAttributes</a></li>
        </ul>
    </ul>
    <br>
    
    <a name="FireTVSTATE"></a>
    <b>Values of STATE</b>
    <ul>
        <ul>
            <li><i>active</i><br>
                devicestatus is unknown, but a check is running (checked via 73_PRESENCE)</li>
            <li><i>absent</i><br>
                device is absent (checked via 73_PRESENCE)</li>
            <li><i>defined</i><br>
                device is defined</li>
            <li><i>disabled</i><br>
                presence-check is disabled, all other functions may still work</li>
            <li><i>present</i><br>
                device is present (checked via 73_PRESENCE)</li>
        </ul>
    </ul>

    <br><br>
    The module provides an additional function <i>FireTV_Remote()</i> which returns
    html code for a graphic remote control usable in FHEMWEB. Just define a weblink 
    device like:
    <br><br>
    <code>define FIRETV_REMOTE weblink htmlCode { FireTV_Remote('FIRETV') }</code><br>
    <code>define FIRETV_REMOTE weblink htmlCode { FireTV_Remote(DEVICE, ICON, COLLAPSIBLE, DEVICELINK) }</code>
    <br><br>
    <b>Parameters:</b>
    <ul>
        <li>DEVICE: Devicename of your FireTV-Device</li>
        <li>ICON: Icon to display in the upper left corner. Default: it_remote</li>
        <li>COLLAPSIBLE: If set to a positive value (1), the remote is displayed collapsed and will expand after clicking it's icon. Default: not set</li>
        <li>DEVICELINK: If not set, the Remote has a clickable title which links to the controlled device. If set to "0" it has no title. If set to any other value, that value will be used as clickable title. Default: not set</li>
    </ul>
</ul>
=end html

=cut
