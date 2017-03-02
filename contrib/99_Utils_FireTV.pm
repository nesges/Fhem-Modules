########################################################################
# 99_Utils_Fire.pm
# utility functions to use with 98_FireTV.pm
#
# Please copy this file from contrib/ to FHEM/ and edit where necessary
#
# 2017 by Thomas Nesges <thomas@nesges.eu>
# $Id$
########################################################################

package main;
use strict;
use warnings;

sub Utils_FireTV_Initialize($$) {
    my ($hash) = @_;
}

# find active FireTV device
# uses a userattribute 'priority'
sub ftv_active(;$) {
    my $default=shift;

    my %score;
    my $maxscore=0;
    my $activedevice;
    my @firedevice = split(/\s/, fhem("list TYPE=FireTV",1));

    foreach my $firedevice (@firedevice) {
        $score{$firedevice} = 1;
        if(Value($firedevice) eq 'present') {
            $score{$firedevice} *= 2;
        }
        
        if($maxscore > 0 && $score{$firedevice} == $maxscore) {
            if(AttrVal($firedevice, 'priority', 0) > AttrVal($activedevice, 'priority', 0)) {
                Log 4, "ftv_active: FireTV $firedevice has higher priority than $activedevice";
                $activedevice = $firedevice;
            }
        } elsif($score{$firedevice} > $maxscore) {
            $maxscore = $score{$firedevice};
            $activedevice = $firedevice;
            Log 4, "ftv_active: new maxscore for FireTV $firedevice (".$score{$firedevice}.")";
        }
    }
    if($activedevice) {
        return $activedevice
    } else {
        Log 4, "ftv_active: found no active host";
        return $default;
    }
}

1;
