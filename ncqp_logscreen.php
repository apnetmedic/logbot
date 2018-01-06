<html>
 <head><title>Log upload processor</title></head>
 <body><div style="font-family: Helvetica,Arial,sans-serif">
  <?php
    // v15.01 - Initial 2015 version.  In LogBot we trust.  Get rid of category checking here.
    // v06 - more 2014 updates - remove bonus stuff as it's now in the perl checker
	// v05 - updates for 2014; addition of perl log checker handoff; more flexible category validation
    // v04 - add QSOs of interest for bonuses
    // v03 - some bug fixes to RST processing
	// v02 - added received logs, added callsign validation
	// v01 - initial alpha version
    $DEBUG = 0;
    $really_email = 01;

    $email_to_name = "NCQP Log Mailbox";
    $email_to_address = "ncqplogs@gmail.com";
    $email_from_name = "NCQP LogBot";
    $email_from_address = "logbot@ncqsoparty.org";
    $logbot_exec = "/home/rars/web-site/ncqsoparty/ncqp-logbot.bin";
//    $logbot_exec = "/usr/bin/perl /var/www/html/ncqsoparty/ncqp-logbot.pl";


    // Common functions
    include("ncqp_functions.php");
    require("email_message.php");

    // MAIN FUNCTION

    if ($DEBUG) { echo "Processing log"; }
    $userpath = $_FILES['uploadlog']['name'];
    $serverpath = $_FILES['uploadlog']['tmp_name'];
    $category = $_POST['category'];
    
    if ($DEBUG) {
        echo "Your filename: [" . $userpath . "]<br>";
        echo "Our filename: [" . $serverpath . "]<br>";
	echo "POST category: [" . $category . "]<br>";
    }

    $fh = fopen($serverpath,'r') or die("Couldn't open log on server");

    if ($DEBUG) { echo "Reading lines.<p>"; }

    // First off, let's validate this is a Cabrillo file.  Should start with START-OF-LOG entry.
    $line = fgets($fh) or die ("Couldn't read -- empty file?");
    list($type,$value) = explode(":", $line);
    if ($type == "START-OF-LOG") {
        if ($DEBUG) {echo "Got start-of-log<br>";}
        // start storing the Cabrillo header for future use.
        $hdr = $line;
     } else {
         die("No 'START-OF-LOG' line found; is this a valid Cabrillo log?");
     }

    // Now process line-by-line until EOF.  At this point we are still in the header.
    $qsos = 0;
    while ($line = fgets($fh)) {
        if ($DEBUG) { echo "Got line [".$line."]<br>"; }
        // Cabrillo format is KEYWORD: DATA - separate the two.
        list($type,$value) = explode(":", $line);
        // Strip leading/trailing spaces from the data.  
        $value = preg_replace( "/\s+(\S.*\S)\s+$/", "$1", $value);

	// Not sure if we are in the header until we see a QSO.    
        switch($type) {
    	    // The only thing we care about in the header is the callsign, so we can skip everything else
	    case "CALLSIGN":
		// strip out any trailing slashes, just get the raw call
		preg_match("/(^[A-Z0-9]+)/",$value, $m);
		$call = $m[1];
		if ($call == "") {
		    die ("Your callsign doesn't appear to be valid.  We got: [" . $value ."<br>");
		}
		if ($DEBUG) { echo "Processing CALLSIGN [" . $call . "]<br>"; }
		break;
	    case "QSO":
		$qsos++;
		if ($DEBUG) { echo "Processing QSO # ". $qsos . "<br>"; }
		break;
	    } // switch

	// If after the check we still have no QSOs, this must be header.  Save it.
    	if ($qsos == 0) {
        	$hdr = $hdr . $line;
    	}

    } // while log lines

   fclose($fh);

   if ($DEBUG) { echo "LOG data -- Call [" . $call ."] Category: [". $category . "] QSOs: [" . 
     $qsos . "]<br>"; }

   // Let's validate the log data.
   $errtxt = '';
   $err = 0;

   // No QSO: lines is a bad sign.
   if ($qsos < 1) {
	$err = 1;
	$errtxt = $errtxt . "We found NO valid QSO: entries in your log.<br>";
   }

   // We need a category from the POST data
   if ($category == 'INVALID') {
	$err = 1;
	$errtxt = $errtxt . "   You did not choose a CATEGORY from the web form.<br>";
   }

   
   // Render a final decision on the log's validity.
   if ($err == 1) {
	// Print error message and ask user for remediation.
	echo "<div style=\"color:#FF0000\"><h2>Error!</h2></div>Your log cannot be processed due to the following error(s):<br><br>";
	echo $errtxt;
	echo "<br>Please correct and re-submit.<br><div style=\"color:#FF0000\">YOUR LOG HAS NOT BEEN SUBMITTED.</div><br><br>";
	echo "For reference, your log's header as received is: <br><pre>" . $hdr . "</pre>";

   } else {  // err=0

	// The log is clean.  Process the log, display success, write call to received logs.

	// Send the file to our scoring robot and hang on to the output.
	$checker_output = array();	// need array to collect output
	$checker_output_text = '';	// will convert it to one string after exec is done
	exec("$logbot_exec $serverpath $category", $checker_output);
	foreach ($checker_output as $co_line) {
		$checker_output_text = $checker_output_text . $co_line . "\n";
	}





	// Generate email and send it.  All this email code from http://www.phpkode.com/folder/s/mime-e-mail-message-sending/
 
	$subject = "LogBot: " . $call . " " . $category;
	$email_message = new email_message_class;
	$email_message->SetEncodedEmailHeader("To",$email_to_address,$email_to_name);
	$email_message->SetEncodedEmailHeader("From",$email_from_address,$email_from_name);
	$email_message->SetEncodedEmailHeader("Reply-To",$email_from_address,$email_from_name);
	$email_message->SetEncodedHeader("Subject",$subject);

	$html_message ="<html>
	<head><title>Log submission for " .$call."</title></head>
	<body>
	<h2>Log submission for ".$call."</h2><br>
	<pre>". $checker_output_text."</pre></body></html>";
	$email_message->CreateQuotedPrintableHTMLPart($html_message,"",$html_part);

	$text_message="This is an HTML message. Please use an HTML capable mail program to read this message.";
	$email_message->CreateQuotedPrintableTextPart($email_message->WrapText($text_message),"",$text_part);

	$alternative_parts=array(
		$text_part,
	        $html_part
	);
	$email_message->CreateAlternativeMultipart($alternative_parts,$alternative_part);
	$related_parts=array($alternative_part);
	$email_message->AddRelatedMultipart($related_parts);

	$attachment=array(
            "FileName"=>$serverpath,
	    "Name"=>$call . ".LOG",
	    "Content-Type"=>"application/octet-stream",
	    "Disposition"=>"attachment",
	);
	$email_message->AddFilePart($attachment);

	// Spew the email to output if we're debugging
	if ($DEBUG)   echo "Email out: " .     var_dump($email_message->parts);

	// Send the email if we are in production
	if ($really_email) {
	    $error=$email_message->Send();
		if(strcmp($error,"")) {
		        echo "<br>Could not send email: $error<br>Please report this to logs@ncqsoparty.org<br>";
		} else {
			// Write log to list of those received
			write_logrec($call);

			// Print success message
			echo "<h2>Your log has been processed.</h2><p>" .
			"We received your log with $qsos QSOs (possibly including dupes.)<br>" .
			"Your log will now show on the submission page as having been received.<br>" .
			"If you discover an error or have problems, mail logs@ncqsoparty.org for help.<br>" .
			"<a href=\"http://ncqsoparty.org\">Back to NCQP Home</a><br><br>" .
			"<h3>Thank You for your participation!</h3>" ;
		} // else error
	} // if really_email

        if ($DEBUG) { 
	    echo "LOG data -- Call [" . $call ."] Category: [". $category . "] QSOs: [" . 
	    $qsos . "]  <br>"; 
	}

   } // if $err


  ?>
 </body>
</html>
