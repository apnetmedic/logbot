#!/usr/bin/perl

###  Deployment Notes ###

# The Deltaforce server doesn't have all our libraries, so need to build ncqp-logbot.bin offline and
# upload it. Use PAR::Packer for this:
#	pp -c -o ncqp-logbot.bin ncqp-logbot.pl
#

### Version History ###

# v2017-01 - Changes for 2017 scoring. Fixed mobile/expedition bonus (had only given
#			 bonus when > 1 county; should be 100 points even if only 1 county activated.
# v2016-01 - Changes for 2016 scoring. Added Google score sheet live update.
# v2015-06 - Fixed soapbox - all 2015 logs to this point didn't dump soapbox :(
# v2015-05 - Fixed too many bonuses for eg NC4QP/ORA NC4QP/WAK etc
# v2015-04 - Added support for N1MM/N1MM+ multi-op QSOs with trailing digit
# v2015-03 - Fixed line score output
# v2015-02 - Add support for ADIF2CBR files.
# v2015-01 - Initial 2015 version.  New bonus stations.  New "extra bonus" feature to
#	   - meet with 2015 structure.  Some header processing cleanup.
# v0.91 - added fix for bonus call with slash; print entire header; more lenient on
# 		  spaces/tabs between key and value in header
# v0.90 - added automatic soapbox grab and dump to file
# v0.89 - new routine for printing lists of things.  Print "locations activated", not just
#	  counties.  Some in-state logs show "NC" for sent exchange.
# v0.88 - fixed some newline processing hiccups, better handling of DOS format text
# v0.87 - grab and print name; log all Q's on server to one big Q file.
# v0.86 - added address grab and report
# v0.85 - added validation of TO location; added print of rejected QSOs; date/time in
#		- CSV output.  Transform bad mults to correct ones (QU/QC).
#		- Transform various modes into DIG (and PH).
# v02 - added counties worked from, lots of "my" and "our" to make strict happy..
# v01 - initial proof of concept

use lib '/home/rars/perl';
use Net::Google::Spreadsheets;
use Net::Google::Spreadsheets::Spreadsheet;
use Net::Google::Spreadsheets::Worksheet;
use Net::Google::Spreadsheets::Row;
use Net::Google::DataAPI::Auth::OAuth2;
use Net::OAuth2::AccessToken;
use Net::Google::DataAPI::Role::Auth;
use Net::Google::DataAPI::Role::Service;
use Storable;
use Moose;

our $DEBUG = 0;
our $version = '2017-01';

our $LINESCOREFILE = 'ncqp-linescores.csv';
our $ALLQSOFILE = 'ncqp-allqso.log';
our $SOAPBOXFILE = 'ncqp-soapbox.txt';

our @bands = ('80m', '40m', '20m', '15m', '10m', '6m', '2m');
our @modes = ('CW', 'PH', 'DIG');

our %points_per_qso = (
    CW => 3,
    PH => 2,
    DIG => 3,
    );
    
# callsigns that are worth bonus points, and how many points each (one bonus per contest)
our %bonus_calls = (
		'W4DW' => 50, 
		'NI4BK' => 50,
		'W1VOA' => 50,
		'NC4QP' => 50,
		);

# mults that are worth bonus points, and how many points each (one bonus per contest)
our %bonus_mults = (
		'GRA' => 50,
		'ANS' => 50,
		);    

# In our contest, if you work all the bonus mults (or calls), you get extra points.
# Trying to make this extensible.. if you hit the "threshold" we add the "extra."
# First one is for the counties - set to a high number to effectively disable
our $extra_bonus_county_thresh = 10000;
our $extra_bonus_county_amount = 50;
# This is the extra bonus for the "stations"
our $extra_bonus_calls_thresh = 10000;
our $extra_bonus_calls_amount = 50;
# Extra bonus for having earned all other bonuses (or some other threshold)
our $extra_bonus_total_thresh = 250;
our $extra_bonus_total_amount = 200;

# How many points we get per activated county as a mobile
our $points_per_activation = 100;

# Map mode names from logs into our modes.  Some programs put out different mode
# names, especially on digital.
our %modemap = (
	CW => 'CW',
	PH => 'PH',
	SSB => 'PH',
	FM => 'PH',
	DIG => 'DIG',
	PK => 'DIG',
	RY => 'DIG',
	PSK => 'DIG',
	MT => 'DIG',
	);
	
# Often-confused mults; transform bad mults to the ones we expect.
# We are being Nice Guys here; the rules say to use the right abbreviations.
our %multmap = (
	QU => 'QC',
	MDC => 'MD',
	NF => 'NL',
	NT => 'NWT',
);

# Initialize the hash of achieved mults from a prebuilt table.
our %mult = &populate_mults();

# Get arguments - no checking here as this is interprocess and I'm lazy
my $filename = shift @ARGV;
my $category = shift @ARGV;

my $log_report = &main($filename, $category);

# Send our output back to the PHP script so it can include it in the email.
print $log_report;

# Main execution flow ends here

sub main {
    my $fn = '';
	$fn = shift;
	my $category = shift;
	my %dupecheck = ();
	my %qso_by_bandmode = ();
	my %qso_by_mode = ();
	my %qso_from = ();
	my %mult_worked = ();

	my $dupes = 0;
	my $counties_from = 0;
	my $qso_valid = 0;
	my $qso_points = 0;
	my $bonus_points;
	my $total_points;
	
	my %bonus_calls_worked = ();
	my %bonus_mults_worked = ();
	
	my $address;
	my $name;
	my $operators;
	my $soapbox='';
	my $start_seen = 0;
    my %hdr = ();
	my $header='';
	
	my $rej_qsos = '';
	my $errored = 0;

	# Category tags to collect from log header	
	my %cat = ();
	
	# Initialize QSO counters per band and mode to zero.
	foreach my $m (@modes) {
		$qso_by_mode{$m} = 0;
		foreach my $b (@bands) {
			$qso_by_bandmode{"$b $m"} = 0;
		}
	}

	print "Operating on file [$fn]\n" if $DEBUG;
	open(IN,"<",$fn) || die "Couldn't read $fn: $!\n";
	
	if ($ALLQSOFILE ne '') {
		open (QSOOUT,">>",$ALLQSOFILE) || die "Couldn't append $ALLQSOFILE: $!\n";
	}

	while(<IN>) {
		s/\n//g;
		s/\r//g;
		print "Considering line: [$_]\n" if $DEBUG;

		# Process log.  Look for keys at beginning of line.  Like QSO: blah or CALLSIGN: W1XYZ
 		next unless (/^(\S*):\s+(\S.*)$/);
		my ($key, $rest) = ($1, $2);
		print "key [$key] rest [$rest]\n" if $DEBUG;		

		# Look for START-OF-LOG at beginning so we aren't saving a ton of useless data
		if ($key =~ /START-OF-LOG/) {
			$start_seen = 1;
			print "Got START-OF-LOG\n" if $DEBUG;		
		}

		# Save the entire log header between START-OF-LOG and first QSO.
		if ($start_seen && $key ne 'QSO') {
			$header = $header . "$key: $rest\n";
			# Capture all the other key/value fields in the %hdr hash
			$hdr{$key} .= $rest;
		}	

		# Catch the many types of ADDRESS field and store for later.
		if (/^ADDRESS/) {
			$address = $address . "     $rest\n";
			print "Adding [$rest] to address\n" if $DEBUG;		
		}
		if ($key eq 'SOAPBOX') {
			$soapbox .= "$rest\n";
			print "Adding [$rest] to soapbox\n" if $DEBUG;		
		}

		if ($key eq 'QSO') { 	
			# The bulk of the routine is processing QSOs.

			# TRlog likes to put stuff in lower-case.  We want upper.
			$rest =~ tr/a-z/A-Z/;
			print "Processing QSO: [$rest]\n" if $DEBUG;						

			# Split the log line out into fields.
			my @fd = split(/\s+/,$rest);
			my ($x,$freq, $mode, $date, $time, $from_call, $from_rst, $from_loc, $to_call, $to_rst, $to_loc);

				
			# Different loggers use different formats.  Figure out what we are looking at.			
			print "QSO has 1+" . $#fd . " fields.\n" if $DEBUG;
			if ($#fd == 9) { 
				# 10 fields means we have RST's present
				($freq, $mode, $date, $time, $from_call, $from_rst, $from_loc, $to_call, $to_rst, $to_loc) = @fd;
				print "processing QSO with RST\n" if $DEBUG;
			} elsif ($#fd == 7) {
				# 8 fields means no RSTs.  That's OK, we don't need them anyway.
				($freq, $mode, $date, $time, $from_call, $from_loc, $to_call, $to_loc) = @fd;
				print "processing QSO withOUT RST\n" if $DEBUG;
			} elsif ($#fd == 8) {
				# There are a few possibilities here, let's find out which.
				if ($fd[5] eq '1') {
				    # We've only seen a few logs with 9 fields - "GenLog" does this:
				    # QSO:  7000 PH 2013-02-24 1511 KG4ZOD        1   ALA    N4GM              BRU
				    ($freq, $mode, $date, $time, $from_call, $x, $from_loc, $to_call, $to_loc) = @fd;
				    print "processing oddball QSO - GenLog?\n" if $DEBUG;
				} elsif ($fd[5] =~ /^59/) {
				    # SP7DQR ADIF2CBR does this:
				    # QSO:  7000 CW 2013-02-22 1513 W4C           599            W1AA          599 NC         
				    ($freq, $mode, $date, $time, $from_call, $x, $to_call, $x, $to_loc) = @fd;
				    $from_loc = "NONE-LOGGED";
				    print "processing oddball QSO - ADIF2CBR?\n" if $DEBUG;
				} elsif ($fd[8] =~ /^\d+/) {
				    # N1MM/N1MM+ does this in a multiop environment; trailing number is station ID
				    # QSO: 14039 CW 2015-03-01 1501 N4E           WAR    W0GXQ         MN         0
				    print "Processing N1MM multi-op QSO\n" if $DEBUG;
				    ($freq, $mode, $date, $time, $from_call, $from_loc, $to_call, $to_loc, $x) = @fd;
				}

			} else {  #field count
				$rej_qsos = $rej_qsos . $rest . "[FORMAT]\n";
				next;
			} # if field count

			# Dump the QSO to a file if we've enabled that in the options
			if ($ALLQSOFILE ne '') {
				print QSOOUT "$freq,$mode,$date,$time,$from_call,$from_loc,$to_call,$to_loc\n";
			}

			# Perform mult transformations to catch some common 'bad' mults
			$to_loc = &transform_mult($to_loc);
			$from_loc = &transform_mult($from_loc);
				
			# Valdiate the QSO.

			# Make sure this is a valid mode.
			print "Checking mode [$mode]\n" if $DEBUG;				

			# Fix up some modes or normalize various digital modes to DIG
			if (defined($modemap{$mode})) {
				$mode = $modemap{$mode};
			} else {
				# Keep QSO for later with reason it was rejected.
				$rej_qsos = $rej_qsos . $rest . " [MODE]\n";
				next;
			}

			# Check for valid band.
			my $band = &freq_to_band($freq);
			print "Got band [$band]\n" if $DEBUG;
			if ($band eq '') {
				$rej_qsos = $rej_qsos . $rest . " [BAND]\n";
				next;
			}


			print "Checking to loc [$to_loc]\n" if $DEBUG;
			unless (defined$mult{$to_loc}) {
				$rej_qsos = $rej_qsos . $rest . " [LOC-TO]\n";
				next;
			}			
								
			# Check for duplicate.  Dupe if we have worked same call, same band, to and from same location.

			my $dupekey = join('|',$band,$mode,$from_loc,$to_call,$to_loc);
			my $bandmode = "$band $mode";
			my $isdupe;

			if (defined($dupecheck{$dupekey})) {
				$isdupe = 'IS DUPE';
				$dupes++;
				$rej_qsos = $rej_qsos . $rest . " [DUPE]\n";
			} else {
				$isdupe = '';
				$dupecheck{$dupekey} = 1;

				# Add this QSO to various running totals
				$qso_by_bandmode{$bandmode}++;
				$qso_by_mode{$mode}++;
				$qso_from{$from_loc}++;
				$mult_worked{$to_loc} = 1;
				$qso_valid++;
					
				# We need the "main" part of the worked call - anything in front of a possible slash.
				# This was implemented some time in 2014, but v2015-05 finishes the job to only count the main
				# part of the call throughout the calcs.
				$to_call =~ /([A-Z0-9]*)\/?.*/;
				my $main_to_call = $1;
					
				if ($bonus_calls{$main_to_call}) {

					print "Got bonus call [$main_to_call] worth [$bonus_calls{$main_to_call}] points\n" if $DEBUG;
					# we keep the point value of working this call in %bonus_calls.  Copy that into an array of bonus calls worked.
					$bonus_calls_worked{$main_to_call} = $bonus_calls{$main_to_call};
				}
					
				if ($bonus_mults{$to_loc}) {
					print "Got bonus mult [$to_loc] worth [$bonus_mults{$to_loc}] points\n" if $DEBUG;
					# we keep the point value of working this mult in %bonus_mults.  Copy that.
					$bonus_mults_worked{$to_loc} = $bonus_mults{$to_loc};
				}
						
					
			} # if dupecheck

			print "band: [$band]  bandmode: [$bandmode] dupe key: [$dupekey]  $isdupe\n" if $DEBUG;				
		} # if QSO
	} # while IN

	
	# Now tally all mults worked - State/province vs County
	my $m_counties = 0;
	my $m_out_of_state=0;
	my $m_invalid=0;
	my @list_counties;
	my @list_out_of_state;
	my @list_invalid;
	my @list_activated;

	foreach my $m (sort keys %mult_worked) {
		# find out what type of mult.  There should be no other options as we screen
		# the bad QSOs elsewhere.
		if ($mult{$m} eq 'C') {
			$m_counties++;
			push (@list_counties,$m);
		} elsif ($mult{$m} eq 'O') {
			$m_out_of_state++;
			push(@list_out_of_state,$m);
		} # if mult
	print "evaluating worked mult $m type $mult{$m} - totals now $m_counties $m_out_of_state $m_invalid\n" if $DEBUG;
	} # foreach $m

	# Catalog counties activated; bonus points for >1 (mobiles)
	my $list_activated='';
	my $counties_activated = 0;
	
	foreach my $m (sort keys %qso_from) {
		# add any location worked FROM to the list.
		push(@list_activated,$m);
		# only count up valid counties as "counties activated" - for bonus purposes.
		next unless ($mult{$m} eq 'C');
		$counties_activated++;
	}


	##### Total up QSO points for all allowed modes #####
	my $qso_report = 'QSO: ';
	foreach my $m (@modes) {
		$qso_points = $qso_points + ($qso_by_mode{$m} * $points_per_qso{$m});
		$qso_report = $qso_report . $m . "=" . $qso_by_mode{$m} . " / ";
		print "Adding " . ($qso_by_mode{$m} * $points_per_qso{$m}) . " points for mode $m - total now $qso_points\n" if $DEBUG;	
	}
	$qso_report = $qso_report . " Total=$qso_valid  - there were $dupes dupes in original log.\n";

	##### Total up bonus points #####
	my $bonus_points_calls = 0;
	my $bonus_points_mults = 0;
	my $bonus_points_extra = 0;
	my $bonus_points_activation = 0;
	
	# bonus for working specific calls
	foreach my $b (keys %bonus_calls_worked) {
		$bonus_points_calls += $bonus_calls_worked{$b};
	}
	
	# bonus for working specific counties
	foreach my $b (keys %bonus_mults_worked) {
		$bonus_points_mults += $bonus_mults_worked{$b};
	}

	# Additional bonus points for working all mults/calls
	if ($bonus_points_calls == $extra_bonus_calls_thresh) {
		$bonus_points_calls += $extra_bonus_calls_amount;
	}
	if ($bonus_points_mults == $extra_bonus_county_thresh) {
		$bonus_points_mults += $extra_bonus_county_amount;
	}
	if ($bonus_points_mults + $bonus_points_calls >= $extra_bonus_total_thresh) {
		$bonus_points_extra += $extra_bonus_total_amount;
	}
	
	# bonus for mobile and expedition activations
	if ($category =~ /^(MOBILE|EXPEDITION)/) {
		$bonus_points_activation = $counties_activated * $points_per_activation;
	}

	# Calculate point totals	
	$bonus_points = $bonus_points_calls + $bonus_points_mults + $bonus_points_activation + $bonus_points_extra;
	my $mults = $m_counties + $m_out_of_state;
	$total_points = ($qso_points*$mults) + $bonus_points;
	
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
	my $date = $year+1900 . "-" . sprintf("%02s",$mon+1) . "-" . sprintf("%02s",$mday);
	my $time = $hour . ":" . sprintf("%02s",$min) . ":" . sprintf("%02s",$sec);
	
	# Create 1-line summary and hash for Google sheet
	my $linehdr = 'DATE,TIME,CALL,CATEGORY,SCORE,QSO,COUNTIES,STATES,MULTS,';
	my $linerpt = "$date,$time,$hdr{'CALLSIGN'},$category" .
		",$total_points,$qso_valid,$m_counties,$m_out_of_state,$mults,";

    # For the "QTH" column in the report, we want either the one location for fixed,
    # or a count for mobile/expedition
    my $qth = '';
    if ($#list_activated == 0) {
        $qth = $list_activated[0];
    } else {
        $qth = $#list_activated + 1;
    }

    my %reportrow = (
        date => $date,
        time => $time,
        call => $hdr{'CALLSIGN'},
        category => $category,
        qth => $qth,
        name => $hdr{'NAME'},
        score => $total_points,
        qso => $qso_valid,
        counties => $m_counties,
        states => $m_out_of_state,
        mults => $mults,
        bonus => $bonus_points,
        address => $address,
        soapbox => $soapbox,
    );

	# Walk the list of bands/modes and add to the summary.
	foreach my $b (@bands) {
		foreach my $m (@modes) {
			$linehdr = $linehdr . "$b$m,";
			$linerpt = $linerpt . $qso_by_bandmode{"$b $m"} . ",";
            my $reportcol = "q$b$m";
            $reportcol =~ tr/A-Z/a-z/;
            $reportrow{$reportcol} = $qso_by_bandmode{"$b $m"};
            print "adding key [$b$m] = [".$qso_by_bandmode{"$b $m"}."] to report hash\n" if $DEBUG;
		}
	}
	
	
	# Generate the results
	my $results = '';

	$results .= "---***   NCQP Log Scoring Report v$version   ***---\n";
	$results .= "Input file is [$fn]\n";
	$results .= "Call: $hdr{'CALLSIGN'}\n";
	$results .= "Name: $hdr{'NAME'}\n";
	$results .= "Address:\n$address";
	$results .= "Operators: $hdr{'OPERATORS'}\n";
	$results .= "Category:  $category \n";
	$results .= "Club/EMCOMM: $hdr{'CLUB'}\n";
	$results .= $qso_report;
	$results .= "QSO points: $qso_points\n";
	$results .= "Mults: County=$m_counties / State/Prov/Other=$m_out_of_state / Total=$mults\n";
	$results .= indent_list("Counties worked:",@list_counties);
	$results .= indent_list("S/P/Other worked:",@list_out_of_state);
	$results .= indent_list("Locations activated:",@list_activated);
	
	if ($counties_activated > 0) {
		$results .= "Counties activated: $counties_activated\n";
	}

	if ($m_invalid > 0) { 
		$results .= "FOUND $m_invalid INVALID MULTS IN LOG ";
		if ($mult_worked{'DX'} ==1) {
			$results .= "(DX is logged)\n";
		} else {
			$results .= "(DX is NOT logged)\n";
		} # if mult_worked
		$results .= indent_list("   Invalid mults:",@list_invalid);
	}; # if m_invalid
	 
	unless ($rej_qsos eq '') {
		$results .= "\nFound INVALID QSOS in log -- PLEASE INSPECT:\n";
		$results .= $rej_qsos;
		$results .= "\n";
	}

	$results .= "\n";
	$results .= "       QSO Score: " . $qso_points * $mults . "\n";
	$results .= "  Callsign bonus: $bonus_points_calls (" . join(' ',keys(%bonus_calls_worked)) . ")\n";
	$results .= "    County bonus: $bonus_points_mults (" . join(' ',keys(%bonus_mults_worked)) . ")\n";
	$results .= "     Extra bonus: $bonus_points_extra\n";
	$results .= "Activation bonus: $bonus_points_activation\n";
	$results .= "    Bonus points: $bonus_points\n";
	$results .= " **TOTAL SCORE**: $total_points\n\n";
	
	$results .= "Band/mode breakdown:\n";

	foreach my $b (@bands) {
		$results .= $b ;
		foreach my $m (@modes) {
			$results .= "\t" . sprintf("%3s",$qso_by_bandmode{"$b $m"}) . " " . $m;
		} # foreach $m
		$results .= "\n";
	} #foreach $b
	
	$results .= "\nLine report:\n$linehdr\n$linerpt\n\n";
	$results .= "Log Header:\n" . $header . "\n\n";
	$results .= "---***   End of report   ***---\n\n";

	if (defined($LINESCOREFILE)) {
		open (LINEOUT,">>",$LINESCOREFILE) || die "Couldn't append $LINESCOREFILE: $!\n";
		print LINEOUT "$linerpt\n";
	}
	if (defined($SOAPBOXFILE) && ($soapbox ne '')) {
		open (SOAPBOX,">>",$SOAPBOXFILE) || die "Couldn't append $SOAPBOXFILE: $!\n";
		print SOAPBOX "$hdr{'CALLSIGN'}\n$soapbox";
	}

    # Auth to GOOG and add a row to our live score spreadsheet
    print "Google: authenticating\n" if $DEBUG;
    my $auth = OAuth_Google();
    print "Google: adding row\n" if $DEBUG;
    Scoresheet_AddRow($auth,\%reportrow);
    print "Google: done\n" if $DEBUG;
	
return $results;	
} # sub main



sub freq_to_band {
	my $f = shift;
	
	print "doing freq_to_band on [$f]\n" if $DEBUG;

	if (($f >= 1800) && ($f <=2000)) { return '160m'; }
	if (($f >= 3500) && ($f <=4000)) { return '80m'; }
	if (($f >= 7000) && ($f <=7300)) { return '40m'; }
	if (($f >= 14000) && ($f <= 14350)) { return '20m' }
	if (($f >= 21000) && ($f <= 21450)) { return '15m' }
	if (($f >= 28000) && ($f <= 29700)) { return '10m' }
	if ($f == 50) { return '6m' };
	if ($f == 144) { return '2m' };

	# Fall through if nothing matched
	return 'unk';
}

sub populate_mults {
	my %mult = ();
	my @counties = ('ALA','ALE','ALL','ANS','ASH','AVE','BEA','BER','BLA','BRU',
					'BUN','BUR','CAB','CAL','CAM','CAR','CAS','CAT','CHA','CHE',
					'CHO','CLA','CLE','COL','CRA','CUM','CUR','DAR','DVD','DAV',
					'DUP','DUR','EDG','FOR','FRA','GAS','GAT','GRM','GRA','GRE',
					'GUI','HAL','HAR','HAY','HEN','HER','HOK','HYD','IRE','JAC',
					'JOH','JON','LEE','LEN','LIN','MAC','MAD','MAR','MCD','MEC',
					'MIT','MON','MOO','NAS','NEW','NOR','ONS','ORA','PAM','PAS',
					'PEN','PEQ','PER','PIT','POL','RAN','RIC','ROB','ROC','ROW',
					'RUT','SAM','SCO','STA','STO','SUR','SWA','TRA','TYR','UNI',
					'VAN','WAK','WAR','WAS','WAT','WAY','WLK','WIL','YAD','YAN');
	my @out_of_state = ('AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI',
						'ID','IL','IN','IA','KS','KY','LA','ME','MD','MA',
						'MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM',
						'NY','ND','OH','OK','OR','PA','RI','SC','SD','TN',
						'TX','UT','VT','VA','WA','WV','WI','WY',
						'NL','NB','NS','PE','QC','ON','MB','SK','AB','BC','NWT','YT','NU',
						'DC','DX');

	foreach my $i (@counties) {
		$mult{$i} = 'C';
	}
	foreach my $i (@out_of_state) {
		$mult{$i} = 'O';
	}
	
	%mult;
}

sub transform_mult {
	my $mult = shift;

	if(defined($multmap{$mult})) {
		$mult = $multmap{$mult};
	}	
	$mult;
}

sub indent_list {
	my ($label, @list) = @_;
	my $MAXLEN = 95 - length($label);
	my $curline = $label;
	my $spacer = "$label ";
	my $alltext = '';

	$spacer =~ s/./ /g;

	foreach my $x (@list) {	
		if (length($curline) + length($x) + 1 > $MAXLEN) {
			$alltext = $alltext . $curline . "\n";
			$curline = $spacer . $x;
		} else {
			$curline = "$curline $x";
		}
	}
	$alltext = $alltext . $curline . "\n";
return($alltext);
}


sub OAuth_Google {
    # Authentication code based on example from gist at 
    #  https://gist.github.com/hexaddikt/6738247

    # Get the token that we saved previously in order to authenticate:
    my $session_filename = "stored_google_access.session";

    my $oauth2 = Net::Google::DataAPI::Auth::OAuth2->new(
        client_id => '781412378522-5oddr1kbnjm054ls5a72eudgmdi9u338.apps.googleusercontent.com',
        client_secret => '7_2Kcx-GFnn2WWNoV0CwNCk3',
        scope => ['http://spreadsheets.google.com/feeds/'],
        redirect_uri => 'https://developers.google.com/oauthplayground',
                             );
    my $session = retrieve($session_filename);

    my $restored_token = Net::OAuth2::AccessToken->session_thaw($session,
        auto_refresh => 1,
        profile => $oauth2->oauth2_webserver,
        );

    $oauth2->access_token($restored_token);
return ($oauth2);
}

sub Scoresheet_AddRow {
    my ($oauth2,$row) = @_;

    if ($DEBUG) {
        print "Adding row:\n";
        foreach my $i (keys %{ $row }) {
            print "$i = $row->{$i}\n";
        }
    }

    # Use stored access token to access spreadsheet
    my $service = Net::Google::Spreadsheets->new(
                         auth => $oauth2);
    print "Authorized.." if $DEBUG;

    my @spreadsheets = $service->spreadsheets();

    # find a spreadsheet by key
    my $spreadsheet = $service->spreadsheet(
        {
            id => '1K_wQAWq1LLJlLyutKyhJPkekVdR4vBjm8qbl73oqkfE'
        }
      );
    print "Found spreadsheet.." if $DEBUG;

    my $worksheet = $spreadsheet->worksheet(
        {
            title => 'Sheet1'
        }
    );
    print "Found worksheet.." if $DEBUG;

    my $new_row = $worksheet->add_row($row);
    print "Added row.\n" if $DEBUG;
}

