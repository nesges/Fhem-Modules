# Fhem-Modules

## Where's the documentation?

* download modules to &lt;FHEMDIR&gt;/FHEM/
* `cd <FHEMDIR>`
* `perl contrib/commandref_join.pl`
* review your local commandref (http://&lt;FHEMURL&gt;/fhem/docs/commandref.html)

or have a look at the Wiki: https://github.com/nesges/Fhem-Modules/wiki

## Installation via update

Issue the following commands to install all included modules via Fhems update mechanism

### add repository

`update add https://raw.githubusercontent.com/nesges/Fhem-Modules/master/controls_nesges-fhem-modules.txt`

### trigger update

`update all https://raw.githubusercontent.com/nesges/Fhem-Modules/master/controls_nesges-fhem-modules.txt`
