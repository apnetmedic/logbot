<?php
	$reclogs_file = "ncqp-received-logs.txt";

	// read list of received logs and return preformat text of log list
	function read_logrec($filename) {
		$callsPerLine = 10;
		$fh = fopen($filename,"r") or die;

		$numcalls = 0;
		$out = "<pre>";
		$callfound = array();

	    while ($line = fgets($fh)) {
			$c = rtrim($line);

			// gather calls into array for dedup and sorting	
			if (!array_key_exists($c, $callfound)) {
				$callfound[$c]=1;
			}
		} // while fgets

		$calls = array_keys($callfound);
		sort($calls);

		foreach ($calls as $c) {
			$numcalls++;
			// formatting   call - call - call, insert dashes and breaks as needed
			if ($numcalls % $callsPerLine == 1) {
				$out = $out . sprintf("%6s", $c);
			} else {
				$out = $out . " - " . sprintf("%6s",$c);
			}
			if ($numcalls % $callsPerLine == 0) {
				$out = $out . "<br>";
			} 
		} // foreach $calls
        $out = $out . "</pre><br>";
		return($out);

	} // function read_logrec

    echo read_logrec($reclogs_file);
?>
