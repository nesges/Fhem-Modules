perl -e 'local $/=undef; open F, "$ARGV[0]"; $f=<F>; close F; 
$f=~s/.*?=begin html(.*?)=end html.*/$1/s; 
$f=~s/<ul>(\s*<)(?!li>)/<div>$1/sg; 
$f=~s/(?<!<\/li)(>\s*)<\/ul>/$1<\/div>/sg; 
$f=~s/(<a href=.)#/$1https:\/\/fhem.de\/commandref.html#/g;
print $f' $1 | pandoc --from html --to mediawiki | sed -e 's/<code>/<tt>/g' | sed -e 's/<\/code>/<\/tt>/g' | sed -e 's/===/=/g'