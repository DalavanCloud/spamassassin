# $Id: HTML.pm,v 1.32 2002/10/11 09:39:10 quinlan Exp $

package Mail::SpamAssassin::HTML;
1;

package Mail::SpamAssassin::PerMsgStatus;
use HTML::Parser 3.00 ();

use strict;

use vars qw{
  $re_loose $re_strict
};

# HTML decoding TODOs
# - add URIs to list for faster URI testing

# elements defined by the HTML 4.01 and XHTML 1.0 DTDs (do not change them!)
$re_loose = 'applet|basefont|center|dir|font|frame|frameset|iframe|isindex|menu|noframes|s|strike|u';
$re_strict = 'a|abbr|acronym|address|area|b|base|bdo|big|blockquote|body|br|button|caption|cite|code|col|colgroup|dd|del|dfn|div|dl|dt|em|fieldset|form|h1|h2|h3|h4|h5|h6|head|hr|html|i|img|input|ins|kbd|label|legend|li|link|map|meta|noscript|object|ol|optgroup|option|p|param|pre|q|samp|script|select|small|span|strong|style|sub|sup|table|tbody|td|textarea|tfoot|th|thead|title|tr|tt|ul|var';

sub html_tag {
  my ($self, $tag, $attr, $num) = @_;

  $self->{html_inside}{$tag} += $num;

  $self->{html}{elements}++ if $tag =~ /^(?:$re_strict|$re_loose)$/io;
  $self->{html}{tags}++;

  if ($num == 1) {
    $self->html_format($tag, $attr, $num);
    $self->html_uri($tag, $attr, $num);
    $self->html_tests($tag, $attr, $num);

    $self->{html_last_tag} = $tag;
  }

  if ($tag =~ /^(?:b|i|u|strong|em|big|center|h\d)$/) {
    $self->{html}{shouting} += $num;

    if ($self->{html}{shouting} > $self->{html}{max_shouting}) {
      $self->{html}{max_shouting} = $self->{html}{shouting};
    }
  }
}

sub html_format {
  my ($self, $tag, $attr, $num) = @_;

  if ($tag eq "p" || $tag eq "hr") {
    push @{$self->{html_text}}, "\n\n";
  }
  elsif ($tag eq "br") {
    push @{$self->{html_text}}, "\n";
  }
  elsif ($tag eq "img" && exists $attr->{alt} && $attr->{alt} ne "") {
    push @{$self->{html_text}}, " $attr->{alt} ";
  }
}

sub html_uri {
  my ($self, $tag, $attr, $num) = @_;
  my $uri;

  if ($tag =~ /^(?:a|area|link)$/) {
    push @{$self->{html_text}}, "URI:$uri " if $uri = $attr->{href};
  }
  elsif ($tag =~ /^(?:img|frame|iframe|embed|script)$/) {
    push @{$self->{html_text}}, "URI:$uri " if $uri = $attr->{src};
  }
  elsif ($tag =~ /^(?:body|table|tr|td)$/) {
    push @{$self->{html_text}}, "URI:$uri " if $uri = $attr->{background};
  }
  elsif ($tag eq "form") {
    push @{$self->{html_text}}, "URI:$uri " if $uri = $attr->{action};
  }
  elsif ($tag eq "base") {
    if ($uri = $attr->{href}) {
      # use <BASE HREF="URI"> to turn relative links into absolute links

      # even if it is a base URI, handle like a normal URI as well
      push @{$self->{html_text}}, "URI:$uri ";

      # a base URI will be ignored by browsers unless it is an absolute
      # URI of a standard protocol
      if ($uri =~ m@^(?:ftp|https?)://@i) {
	# remove trailing filename, if any; base URIs can have the
	# form of "http://foo.com/index.html"
	$uri =~ s@^([a-z]+://[^/]+/.*?)[^/\.]+\.[^/\.]{2,4}$@$1@i;
	# Make sure it ends in a slash
	$uri .= "/" unless $uri =~ m@/$@;
	$self->{html}{base_href} = $uri;
      }
    }
  }
}

# input values from 0 to 255
sub rgb_to_hsv {
  my ($r, $g, $b) = @_;
  my ($h, $s, $v, $max, $min);

  if ($r > $g) {
    $max = $r; $min = $g;
  }
  else {
    $min = $r; $max = $g;
  }
  $max = $b if $b > $max;
  $min = $b if $b < $min;
  $v = $max;
  $s = $max ? ($max - $min) / $max : 0;
  if ($s == 0) {
    $h = undef;
  }
  else {
    my $cr = ($max - $r) / ($max - $min);
    my $cg = ($max - $g) / ($max - $min);
    my $cb = ($max - $b) / ($max - $min);
    if ($r == $max) {
      $h = $cb - $cg;
    }
    elsif ($g == $max) {
      $h = 2 + $cr - $cb;
    }
    elsif ($b == $max) {
      $h = 4 + $cg - $cr;
    }
    $h *= 60;
    $h += 360 if $h < 0;
  }
  return ($h, $s, $v);
}

# the most common HTML colors
my %name_to_rgb = (
  red           => '#ff0000',
  black         => '#000000',
  blue          => '#0000ff',
  white         => '#ffffff',
  navy          => '#000080',
  green         => '#008000',
  orange        => '#ffa500',
  yellow        => '#ffff00',
  fuchsia       => '#ff00ff',
  lime          => '#00ff00',
  maroon        => '#800000',
  darkblue      => '#00008b',
  gray          => '#808080',
  purple        => '#800080',
  magenta       => '#ff00ff',
  pink          => '#ffc0cb',
);

sub name_to_rgb {
  return $name_to_rgb{$_[0]} || $_[0];
}

sub html_tests {
  my ($self, $tag, $attr, $num) = @_;

  if ($tag eq "table" && exists $attr->{border} && $attr->{border} =~ /(\d+)/)
  {
    $self->{html}{thick_border} = 1 if $1 > 1;
  }
  if ($tag eq "script") {
    $self->{html}{javascript} = 1;
  }
  if ($tag eq "script" && exists $attr->{language}) {
    $self->{html}{t_javascript} = 1 if $attr->{language} =~ /javascript/i;
  }
  if ($tag =~ /^(?:body|frame)$/) {
    for (keys %$attr) {
      if (/^on(?:Load|UnLoad|BeforeUnload)$/i)
      {
	$self->{html}{javascript_very_unsafe} = 1;
        if ($attr->{$_} =~ /\.open\s*\(/) { $self->{html}{window_open} = 1; }
        if ($attr->{$_} =~ /\.blur\s*\(/) { $self->{html}{window_blur} = 1; }
      }
    }
  }
  if ($tag eq "body" && exists $attr->{bgcolor}) {
    $self->{html}{bgcolor} = lc($attr->{bgcolor});
    $self->{html}{bgcolor} = name_to_rgb($self->{html}{bgcolor});
    $self->{html}{bgcolor_nonwhite} = 1 if $self->{html}{bgcolor} !~ /^\#?ffffff$/;
  }
  if ($tag eq "font" && exists $attr->{size}) {
    $self->{html}{big_font} = 1 if (($attr->{size} =~ /^\s*(\d+)/ && $1 >= 3) ||
			    ($attr->{size} =~ /\+(\d+)/ && $1 > 1));
  }
  if ($tag eq "font" && exists $attr->{color}) {
    my $c = lc($attr->{color});
    $self->{html}{font_color_nohash} = 1 if $c =~ /^[0-9a-f]{6}$/;
    $self->{html}{font_color_unsafe} = 1 if ($c =~ /^\#?[0-9a-f]{6}$/ &&
				     $c !~ /^\#?(?:00|33|66|80|99|cc|ff){3}$/);
    $self->{html}{font_color_name} = 1 if ($c !~ /^\#?[0-9a-f]{6}$/ &&
				   $c !~ /^(?:navy|gray|red|white)$/);
    $c = name_to_rgb($c);
    $self->{html}{font_invisible} = 1 if (exists $self->{html}{bgcolor} &&
                                substr($c,-6) eq substr($self->{html}{bgcolor},-6));
    if ($c =~ /^\#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/) {
      my ($h, $s, $v) = rgb_to_hsv(hex($1), hex($2), hex($3));
      if (!defined($h)) {
	$self->{html}{font_gray} = 1 unless ($v == 0 || $v == 255);
      }
      elsif ($h < 30 || $h >= 330) {
	$self->{html}{font_red} = 1;
      }
      elsif ($h < 90) {
	$self->{html}{font_yellow} = 1;
      }
      elsif ($h < 150) {
	$self->{html}{font_green} = 1;
      }
      elsif ($h < 210) {
	$self->{html}{font_cyan} = 1;
      }
      elsif ($h < 270) {
	$self->{html}{font_blue} = 1;
      }
      elsif ($h < 330) {
	$self->{html}{font_magenta} = 1;
      }
    }
    else {
      $self->{html}{font_color_unknown} = 1;
    }
  }
  if ($tag eq "font" && exists $attr->{face}) {
    $self->{html}{font_face_caps} = 1 if $attr->{face} =~ /[A-Z]{3}/;
    if ($attr->{face} !~ /^[a-z][a-z -]*[a-z](?:,\s*[a-z][a-z -]*[a-z])*$/i) {
      $self->{html}{font_face_bad} = 1;
    }
    for (split(/,/, lc($attr->{face}))) {
      $self->{html}{font_face_odd} = 1 if ! /^\s*(?:arial|comic sans ms|courier new|geneva|helvetica|ms mincho|sans-serif|serif|tahoma|times new roman|verdana)\s*$/i;
    }
  }

  if (exists($attr->{style})) {
    if ($attr->{style} =~ /font(?:-size)?:\s*([\d\.]+)(p[tx])/i) {
      my $size = $1;
      my $type = $2;

      $self->{html}{big_font_B} = 1 if (lc($type) eq "pt" && $size > 12);
      $self->{html}{font_px}    = 1 if (lc($type) eq "px");
    }
    $self->{html}{line_height} = 1 if ($attr->{style} =~ /line-height/i);
  }

  if (($tag eq "img" && exists $attr->{src} &&
       $attr->{src} =~ /(?:\?|[a-f\d]{12,})/i) ||
      ($tag =~ /^(?:body|table|tr|td)$/ && exists $attr->{background} &&
       $attr->{background} =~ /(?:\?|[a-f\d]{12,})/i))
  {
    $self->{html}{web_bugs} = 1;
  }

  # TESTING
  if (($tag eq "img" && exists $attr->{src} &&
       $attr->{src} =~ /(?:\?|[a-f\d]{12,})/i &&
       $attr->{src} !~ /\.(?:jpe?g|gif|png)$/i) ||
      ($tag =~ /^(?:body|table|tr|td)$/ && exists $attr->{background} &&
       $attr->{background} =~ /(?:\?|[a-f\d]{12,})/i &&
       $attr->{background} !~ /\.(?:jpe?g|gif|png)$/i))
  {
    $self->{html}{t_web_bugs1} = 1;
  }

  # TESTING
  if (($tag eq "img" && exists $attr->{src} &&
       ($attr->{src} =~ /\?/ ||
	($attr->{src} =~ /[a-f\d]{12,}/i &&
	 $attr->{src} !~ /\.(?:jpe?g|gif|png)$/i))) ||
      ($tag =~ /^(?:body|table|tr|td)$/ && exists $attr->{background} &&
       ($attr->{background} =~ /\?/ ||
	($attr->{background} =~ /[a-f\d]{12,}/i &&
	 $attr->{background} !~ /\.(?:jpe?g|gif|png)$/i))))
  {
    $self->{html}{t_web_bugs2} = 1;
  }

  # TESTING
  if ($tag eq "img" && exists $attr->{alt} && !exists $attr->{src}) {
    $self->{html}{img_alt_only1} = 1;
  }

  # TESTING
  if ($tag eq "img" && exists $attr->{alt} &&
      !(exists $attr->{src} && $attr->{src} =~ /\.(?:jpe?g|gif|png)$/i))
  {
    $self->{html}{img_alt_only2} = 1;
  }

  # TESTING: this is too close to HTML_WEB_BUGS to justify both rules
  if ($tag eq "img" &&
      exists $attr->{src} && $attr->{src} !~ /\.(?:jpe?g|gif|png)$/i)
  {
    $self->{html}{img_src_no_image} = 1;
  }

  if ($tag eq "img") {
      $self->{html}{num_imgs}++;

      $self->{html}{consec_imgs}++;

      if ($self->{html}{consec_imgs} > $self->{html}{max_consec_imgs}) {
          $self->{html}{max_consec_imgs} = $self->{html}{consec_imgs};
      }
  }

  if ($tag eq "img" && exists $attr->{width} && $attr->{width} =~ /^\d+$/ && exists $attr->{height} && $attr->{height} =~ /^\d+$/ ) {
      my $area = $attr->{width} * $attr->{height};
      $self->{html}{total_image_area} += $area;

      if (($attr->{width} > 0) && ($attr->{height} > 0)) {
          my $ratio = ($attr->{width} + 0.0) / ($attr->{height} + 0.0);

          $self->{html}{min_img_ratio} = $ratio
            if ($self->{html}{min_img_ratio} eq "inf" || $ratio < $self->{html}{min_img_ratio});
          $self->{html}{max_img_ratio} = $ratio
            if ($ratio > $self->{html}{max_img_ratio});
      }
  }
  if ($tag eq "form" && exists $attr->{action}) {
    $self->{html}{form_action_mailto} = 1 if $attr->{action} =~ /mailto:/i
  }
  # TESTING: input form tests
  if ($tag eq "input") {
    if (exists $attr->{type} && $attr->{type} =~ /hidden/i)
    {
      if ((exists $attr->{name} &&
	   $attr->{name} =~ /(?:mail|recipient|from)/i) ||
	  (exists $attr->{value} &&
	   $attr->{value} =~ /(?:\S+\@\S+|remove|subscrib|unsub)/i))
      {
	$self->{html}{t_form_hidden_email1} = 1;
      }
      if ((exists $attr->{name} &&
	   $attr->{name} =~ /(?:mail|recipient|from)/i) &&
	  (exists $attr->{value} &&
	   $attr->{value} =~ /\S+\@\S+/))
      {
	$self->{html}{t_form_hidden_email2} = 2;
      }
    }
  }
  if ($tag =~ /^i?frame$/) {
    $self->{html}{relaying_frame} = 1;
  }
  if ($tag =~ /^(?:object|embed)$/) {
    $self->{html}{embeds} = 1;
  }
  if ($tag eq "title" &&
      !(exists $self->{html_inside}{body} && $self->{html_inside}{body} > 0))
  {
    $self->{html}{title_text} = "";
  }

  $self->{html}{header_tag} = 1 if ($tag =~ /^h\d$/);
}

sub html_text {
  my ($self, $text) = @_;

  if ($text =~ /\S/) {
    # measuring consecutive image tags with no intervening text
    $self->{html}{consec_imgs} = 0;
  }

  if (exists $self->{html_inside}{script} && $self->{html_inside}{script} > 0)
  {
    if ($text =~ /\.open\s*\(/) { $self->{html}{window_open} = 1; }
    if ($text =~ /\.blur\s*\(/) { $self->{html}{window_blur} = 1; }
    return;
  }

  if (exists $self->{html_inside}{style} && $self->{html_inside}{style} > 0) {
    if ($text =~ /font(?:-size)?:\s*([\d\.]+)(p[tx])/i) {
      my $size = $1;
      my $type = $2;

      $self->{html}{big_font_B} = 1 if (lc($type) eq "pt" && $size > 12);
      $self->{html}{font_px}    = 1 if (lc($type) eq "px");
    }
    $self->{html}{line_height} = 1 if ($text =~ /line-height/i);

    return;
  }

  if (!(exists $self->{html_inside}{body} && $self->{html_inside}{body} > 0) &&
        exists $self->{html_inside}{title} && $self->{html_inside}{title} > 0)
  {
    $self->{html}{title_text} .= $text;
  }
  $text =~ s/\n// if $self->{html_last_tag} eq "br";
  push @{$self->{html_text}}, $text;
}

sub html_comment {
  my ($self, $text) = @_;

  $self->{html}{comment_8bit} = 1 if $text =~ /[\x80-\xff]{3,}/;
  $self->{html}{comment_email} = 1 if $text =~ /\S+\@\S+/;
  $self->{html}{comment_saved_url} = 1 if $text =~ /<!-- saved from url=\(\d{4}\)/;
  $self->{html}{comment_sky} = 1 if $text =~ /SKY-(?:Email-Address|Database|Mailing|List)/;
  $self->{html}{comment_unique_id} = 1 if $text =~ /<!--\s*(?:[\d.]+|[a-f\d]{5,}|\S{10,})\s*-->/i;

  if (exists $self->{html_inside}{style} && $self->{html_inside}{style} > 0) { 
    if ($text =~ /font(?:-size)?:\s*([\d\.]+)(p[tx])/i) {
      my $size = $1;
      my $type = $2;

      $self->{html}{big_font_B} = 1 if (lc($type) eq "pt" && $size > 12);
      $self->{html}{font_px}    = 1 if (lc($type) eq "px");
    }
    $self->{html}{line_height} = 1 if ($text =~ /line-height/i);
  }
}

###########################################################################
# HTML parser tests
###########################################################################

# A possibility for spotting heavy HTML spam and image-only spam
# Submitted by Michael Moncur 7/26/2002, see bug #608
sub html_percentage {
  my ($self, undef, $min, $max) = @_;

  my $html_percent = $self->{html}{ratio} * 100;
  return ($html_percent > $min && $html_percent <= $max);
}

sub html_tag_balance {
  my ($self, undef, $tag, $expr) = @_;
  return exists $self->{html_inside}{$tag} && eval "$self->{html_inside}{$tag} $expr";
}

sub html_tag_exists {
  my ($self, undef, $tag) = @_;
  return exists $self->{html_inside}{$tag};
}

sub html_test {
  my ($self, undef, $test) = @_;
  return $self->{html}{$test};
}

sub html_eval {
  my ($self, undef, $test, $expr) = @_;
  return exists $self->{html}{$test} && eval "qq{\Q$self->{html}{$test}\E} $expr";
}

sub html_message {
  my ($self) = @_;

  return (exists $self->{html}{elements} &&
	  ($self->{html}{elements} >= 8 ||
	   $self->{html}{elements} >= $self->{html}{tags} / 2));
}

sub html_range {
  my ($self, undef, $test, $min, $max) = @_;

  $max ||= "inf";

  return 0 unless exists $self->{html}{$test};

  $test = $self->{html}{$test};
  return ($test > $min && $test <= $max);
}

1;
__END__
