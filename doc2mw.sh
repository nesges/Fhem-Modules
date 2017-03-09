perl -e 'local $/=undef; open F, "$ARGV[0]"; $f=<F>; close F; 
$f=~s/.*?=begin html(.*?)=end html.*/$1/s; 
$f=~s/<ul>(\s*<)(?!li>)/<div>$1/sg; 
$f=~s/(?<!<\/li)(>\s*)<\/ul>/$1<\/div>/sg; 
$f=~s/(<a href=.)#/$1https:\/\/fhem.de\/commandref.html#/g;
$w=$f;
$w=~s/(<pre>.*?)(?<!<br\/><tt>)[\r\n]+(.*?<\/pre>)/$1<\/tt><br\/><tt>$2/sg; 
while($w ne $f) {
    $f=$w;
    $w=~s/(<pre>.*?)(?<!<br\/><tt>)[\r\n]+(.*?<\/pre>)/$1<\/tt><br\/><tt>$2/sg; 
}
$f=~s/<(\/?)pre>/<$1tt>/sg; 
print $f' $1 | pandoc --from html --to mediawiki | sed -e 's/<code>/<tt>/g' | sed -e 's/<\/code>/<\/tt>/g' | sed -e 's/===/=/g'