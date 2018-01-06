<html><head><title>NCQP Logs Update</title></head>
<div style="font:Arial">

Updating logs received: <br>

<?php

    include('ncqp_functions.php');
    $DEBUG = 0;

	// list of POST fields potentially containing callsigns.
	$calls = array('call1','call2','call3','call4');

	foreach ($calls as $i) {
		$j = strtoupper($_POST[$i]);
		if ($j != '') {
			echo "$j ";
			write_logrec($j);
		} else {
			if ($DEBUG) { 
				echo "skip! "; 
			} // if DEBUG
		}// if $j..
	} // foreach
	echo " done.<br>\n";

?>

<br>
<a href="ncqp_admin.php">Back to admin page</a>
</div></body></html>

