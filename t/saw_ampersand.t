#!/usr/bin/perl

# detect use of dollar-ampersand somewhere in the perl interpreter;
# once it is used once, it slows down every regexp match thereafter.

BEGIN {
  if (-e 't/test_dir') { # if we are running "t/rule_tests.t", kluge around ...
    chdir 't';
  }

  if (-e 'test_dir') {            # running from test directory, not ..
    unshift(@INC, '../blib/lib');
    unshift(@INC, '../lib');
  }
}

my $prefix = '.';
if (-e 'test_dir') {            # running from test directory, not ..
  $prefix = '..';
}

use lib '.'; use lib 't';
use SATest; sa_t_init("saw_ampersand");
use Test;
use Carp qw(croak);

our $RUN_THIS_TEST;
use constant HAS_MODULE => eval { require Devel::SawAmpersand; };

BEGIN {
  $RUN_THIS_TEST = conf_bool('run_saw_ampersand_test')
                    && HAS_MODULE;
  plan tests => (!$RUN_THIS_TEST ? 0 : 40)
};

print "NOTE: this test requires 'run_saw_ampersand_test' set to 'y'.\n";
exit unless $RUN_THIS_TEST;

# ---------------------------------------------------------------------------

use strict;
require Mail::SpamAssassin;
require Devel::SawAmpersand;

# it is important to order these from least-plugin-code-run to most.

print "\ntrying local-tests-only with default plugins\n";
tryone (1, "");

print "\ntrying net with only local rule plugins\n";


# kill all 'loadplugin' lines
foreach my $file 
        (<log/localrules.tmp/*.pre>, <log/test_rules_copy/*.pre>) #*/
{
  rename $file, "$file.bak" or die "rename $file failed";
  open IN, "<$file.bak" or die "cannot read $file.bak";
  open OUT, ">$file" or die "cannot write $file";
  while (<IN>) {
    s/^loadplugin/###loadplugin/g;
    print OUT;
  }
  close IN;
  close OUT;
}


my $plugins = q{
  loadplugin Mail::SpamAssassin::Plugin::Check
  loadplugin Mail::SpamAssassin::Plugin::HTTPSMismatch
  loadplugin Mail::SpamAssassin::Plugin::URIDetail
  loadplugin Mail::SpamAssassin::Plugin::Bayes
  loadplugin Mail::SpamAssassin::Plugin::BodyEval
  loadplugin Mail::SpamAssassin::Plugin::DNSEval
  loadplugin Mail::SpamAssassin::Plugin::HTMLEval
  loadplugin Mail::SpamAssassin::Plugin::HeaderEval
  loadplugin Mail::SpamAssassin::Plugin::MIMEEval
  loadplugin Mail::SpamAssassin::Plugin::RelayEval
  loadplugin Mail::SpamAssassin::Plugin::URIEval
  loadplugin Mail::SpamAssassin::Plugin::WLBLEval
  loadplugin Mail::SpamAssassin::Plugin::VBounce
};
write_plugin_pre($plugins);
tryone (0, "");

print "\ntrying net with more local rule plugins\n";

$plugins .= q{
  loadplugin Mail::SpamAssassin::Plugin::SpamCop
  loadplugin Mail::SpamAssassin::Plugin::AntiVirus
  loadplugin Mail::SpamAssassin::Plugin::TextCat
  loadplugin Mail::SpamAssassin::Plugin::AccessDB
  loadplugin Mail::SpamAssassin::Plugin::WhiteListSubject
  loadplugin Mail::SpamAssassin::Plugin::MIMEHeader
  loadplugin Mail::SpamAssassin::Plugin::ReplaceTags
  loadplugin Mail::SpamAssassin::Plugin::Shortcircuit
  loadplugin Mail::SpamAssassin::Plugin::Rule2XSBody
};
write_plugin_pre($plugins);
tryone (0, "");

print "\ntrying net with DCC rule plugins\n";
$plugins .= q{
  loadplugin Mail::SpamAssassin::Plugin::DCC
};
write_plugin_pre($plugins);
tryone (0, "");

print "\ntrying net with Razor2 rule plugins\n";
$plugins .= q{
  loadplugin Mail::SpamAssassin::Plugin::Razor2
};
write_plugin_pre($plugins);
tryone (0, "
score RAZOR2_CHECK 0
score RAZOR2_CF_RANGE_51_100 0
score RAZOR2_CF_RANGE_E4_51_100 0
score RAZOR2_CF_RANGE_E8_51_100 0
");

print "\ntrying net with Razor2 rule plugins\n";
$plugins .= q{
  loadplugin Mail::SpamAssassin::Plugin::Razor2
};
write_plugin_pre($plugins);
tryone (0, "
score RAZOR2_CHECK 1
score RAZOR2_CF_RANGE_51_100 1
score RAZOR2_CF_RANGE_E4_51_100 1
score RAZOR2_CF_RANGE_E8_51_100 1
");

print "\ntrying net with DKIM rule plugins\n";
$plugins .= q{
  loadplugin Mail::SpamAssassin::Plugin::DKIM
};
write_plugin_pre($plugins);
tryone (0, "");

print "\ntrying net with Pyzor rule plugins\n";
$plugins .= q{
  loadplugin Mail::SpamAssassin::Plugin::Pyzor
};
write_plugin_pre($plugins);
tryone (0, "");

print "\ntrying net with all default non-local rule plugins\n";

# TODO: unportable
system "perl -pi.bak -e 's/^###loadplugin/loadplugin/g' ".
                " log/localrules.tmp/*.pre log/test_rules_copy/*.pre";

($? >> 8 != 0) and die "perl failed";

tryone (0, "");
ok 1;

exit;

# ---------------------------------------------------------------------------

sub write_plugin_pre {
  my $cftext = shift;
  open OUT, ">log/localrules.tmp/test.pre";
  print OUT $cftext;
  close OUT or die;
}

sub tryone {
  my ($ltests, $cftext) = @_;

  print "  SawAmpersand test using local_tests_only=>$ltests,\n".
        "  post_config_text=>'$cftext'\n\n";

  # note: do not use debug, that uses dollar-ampersand in rule debug output
  # (hit_rule_plugin_code() in lib/Mail/SpamAssassin/Plugin/Check.pm)
  my $sa = create_saobj({
    'dont_copy_prefs' => 1,
    # 'debug' => 1,
    'local_tests_only' => $ltests,
    'post_config_text' => $cftext
  });

  $sa->init(1);
  ok($sa);

  open (IN, "<data/spam/009");
  my $mail = $sa->parse(\*IN);
  close IN;

  my $status = $sa->check($mail);
  my $rewritten = $status->rewrite_mail();
  my $msg = $status->{msg};

  ok $rewritten =~ /message\/rfc822; x-spam-type=original/;
  ok $rewritten =~ /X-Spam-Flag: YES/;

  print "saw ampersand?\n";
  ok (!Devel::SawAmpersand::sawampersand());

  # Devel::SawAmpersand::sawampersand() and croak("\$"."\& is in effect! dying");

  $mail->finish();
  $status->finish();
}

