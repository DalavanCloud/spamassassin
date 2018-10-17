# <@LICENSE>
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to you under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at:
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

use strict;  # make Test::Perl::Critic happy
package Mail::SpamAssassin::Dns; 1;

package Mail::SpamAssassin::PerMsgStatus;

use strict;
use warnings;
# use bytes;
use re 'taint';

use Mail::SpamAssassin::Conf;
use Mail::SpamAssassin::PerMsgStatus;
use Mail::SpamAssassin::AsyncLoop;
use Mail::SpamAssassin::Constants qw(:ip);
use Mail::SpamAssassin::Util qw(untaint_var am_running_on_windows idn_to_ascii);

use File::Spec;
use IO::Socket;
use POSIX ":sys_wait_h";


our $KNOWN_BAD_DIALUP_RANGES; # Nothing uses this var???
our $LAST_DNS_CHECK = 0;

# use very well-connected domains (fast DNS response, many DNS servers,
# geographical distribution is a plus, TTL of at least 3600s)
our @EXISTING_DOMAINS = qw{
  adelphia.net
  akamai.com
  apache.org
  cingular.com
  colorado.edu
  comcast.net
  doubleclick.com
  ebay.com
  gmx.net
  google.com
  intel.com
  kernel.org
  linux.org
  mit.edu
  motorola.com
  msn.com
  sourceforge.net
  sun.com
  w3.org
  yahoo.com
};

our $IS_DNS_AVAILABLE = undef;

#Removed $VERSION per BUG 6422
#$VERSION = 'bogus';     # avoid CPAN.pm picking up razor ver

###########################################################################

BEGIN {
  # some trickery. Load these modules right here, if possible; that way, if
  # the module exists, we'll get it loaded now.  Very useful to avoid attempted
  # loads later (which will happen).  If we do a fork(), we could wind up
  # attempting to load these modules in *every* subprocess.
  #
# # We turn off strict and warnings, because Net::DNS and Razor both contain
# # crud that -w complains about (perl 5.6.0).  Not that this seems to work,
# # mind ;)
# no strict;
# local ($^W) = 0;

  no warnings;
  eval {
    require Net::DNS;
    require Net::DNS::Resolver;
  };
  eval {
    require MIME::Base64;
  };
  eval {
    require IO::Socket::UNIX;
  };
};

###########################################################################

sub do_rbl_lookup {
  my ($self, $rule, $set, $type, $host, $subtest) = @_;

  $host = idn_to_ascii($host);
  my $key = "dns:$type:$host";

  my $ent = {
    key => $key,
    zone => $host,  # serves to fetch other per-zone settings
    type => "DNSBL-".$type,
    set => $set,
    subtest => $subtest,
    rulename => $rule,
  };
  $ent = $self->{async}->bgsend_and_start_lookup(
        $host, $type, undef, $ent,
        sub { my($ent, $pkt) = @_; $self->process_dnsbl_result($ent, $pkt) },
      master_deadline => $self->{master_deadline} );
}

sub do_dns_lookup {
  my ($self, $rule, $type, $host) = @_;

  $host = idn_to_ascii($host);
  $host =~ s/\.\z//s;  # strip a redundant trailing dot
  my $key = "dns:$type:$host";

  my $ent = {
    key => $key,
    zone => $host,  # serves to fetch other per-zone settings
    type => "DNSBL-".$type,
    rules => [ $rule ],
    # id is filled in after we send the query below
  };
  $ent = $self->{async}->bgsend_and_start_lookup(
      $host, $type, undef, $ent,
      sub { my($ent, $pkt) = @_; $self->process_dnsbl_result($ent, $pkt) },
    master_deadline => $self->{master_deadline} );
  $ent;
}

###########################################################################

sub dnsbl_hit {
  my ($self, $rule, $question, $answer) = @_;

  my $log = "";
  if (substr($rule, 0, 2) eq "__") {
    # don't bother with meta rules
  } elsif ($answer->type eq 'TXT') {
    # txtdata returns a non- zone-file-format encoded result, unlike rdstring;
    # avoid space-separated RDATA <character-string> fields if possible,
    # txtdata provides a list of strings in a list context since Net::DNS 0.69
    $log = join('',$answer->txtdata);
    utf8::encode($log)  if utf8::is_utf8($log);
    local $1;
    $log =~ s{ (?<! [<(\[] ) (https? : // \S+)}{<$1>}xgi;
  } else {  # assuming $answer->type eq 'A'
    local($1,$2,$3,$4,$5);
    if ($question->string =~ /^((?:[0-9a-fA-F]\.){32})(\S+\w)/) {
      $log = ' listed in ' . lc($2);
      my $ipv6addr = join('', reverse split(/\./, lc $1));
      $ipv6addr =~ s/\G(....)/$1:/g;  chop $ipv6addr;
      $ipv6addr =~ s/:0{1,3}/:/g;
      $log = $ipv6addr . $log;
    } elsif ($question->string =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\S+\w)/) {
      $log = "$4.$3.$2.$1 listed in " . lc($5);
    } elsif ($question->string =~ /^(\S+)(?<!\.)/) {
      $log = "listed in $1";
    }
  }

  # TODO: this may result in some log messages appearing under the
  # wrong rules, since we could see this sequence: { test one hits,
  # test one's message is logged, test two hits, test one fires again
  # on another IP, test one's message is logged for that other IP --
  # but under test two's heading }.   Right now though it's better
  # than just not logging at all.

  $self->{already_logged} ||= { };
  if ($log && !$self->{already_logged}->{$log}) {
    $self->test_log($log);
    $self->{already_logged}->{$log} = 1;
  }

  if (!$self->{tests_already_hit}->{$rule}) {
    $self->got_hit($rule, "RBL: ", ruletype => "dnsbl");
  }
}

sub dnsbl_uri {
  my ($self, $question, $answer) = @_;

  my $rdatastr;
  if ($answer->UNIVERSAL::can('txtdata')) {
    # txtdata returns a non- zone-file-format encoded result, unlike rdstring;
    # avoid space-separated RDATA <character-string> fields if possible,
    # txtdata provides a list of strings in a list context since Net::DNS 0.69
    $rdatastr = join('',$answer->txtdata);
  } else {
    # rdatastr() is historical/undocumented, use rdstring() since Net::DNS 0.69
    $rdatastr = $answer->UNIVERSAL::can('rdstring') ? $answer->rdstring
                                                    : $answer->rdatastr;
    # encoded in a RFC 1035 zone file format (escaped), decode it
    $rdatastr =~ s{ \\ ( [0-9]{3} | (?![0-9]{3}) . ) }
                  { length($1)==3 && $1 <= 255 ? chr($1) : $1 }xgse;
  }
  # Bug 7236: Net::DNS attempts to decode text strings in a TXT record as
  # UTF-8 since version 0.69, which is undesired: octets failing the UTF-8
  # decoding are converted to a Unicode "replacement character" U+FFFD, and
  # ASCII text is unnecessarily flagged as perl native characters.
  utf8::encode($rdatastr)  if utf8::is_utf8($rdatastr);

  my $qname = $question->qname;
  if (defined $qname && defined $rdatastr) {
    my $qclass = $question->qclass;
    my $qtype = $question->qtype;
    my @vals;
    push(@vals, "class=$qclass") if $qclass ne "IN";
    push(@vals, "type=$qtype") if $qtype ne "A";
    my $uri = "dns:$qname" . (@vals ? "?" . join(";", @vals) : "");

    $self->{dnsuri}{$uri}{$rdatastr} = 1;
    dbg("dns: hit <$uri> $rdatastr");
  }
}

# called as a completion routine to bgsend by DnsResolver::poll_responses;
# returns 1 on successful packet processing
sub process_dnsbl_result {
  my ($self, $ent, $pkt) = @_;

  return if !$pkt;
  my $question = ($pkt->question)[0];
  return if !$question;

  # DNSBL tests are here
  foreach my $answer ($pkt->answer) {
    next if !$answer;
    # track all responses
    $self->dnsbl_uri($question, $answer);
    my $answ_type = $answer->type;
    # TODO: there are some CNAME returns that might be useful
    next if $answ_type ne 'A' && $answ_type ne 'TXT';
    if ($answ_type eq 'A') {
      # Net::DNS::RR::A::address() is available since Net::DNS 0.69
      my $ip_address = $answer->UNIVERSAL::can('address') ? $answer->address
                                                          : $answer->rdatastr;
      # skip any A record that isn't on 127.0.0.0/8
      next if $ip_address !~ /^127\./;
    }
    $self->dnsbl_hit($ent->{rulename}, $question, $answer);
    if (defined $self->{rbl_subs}{$ent->{set}}) {
      $self->process_dnsbl_set($ent->{set}, $question, $answer);
    }
  }
  return 1;
}

sub process_dnsbl_set {
  my ($self, $set, $question, $answer) = @_;

  my $rdatastr;
  if ($answer->UNIVERSAL::can('txtdata')) {
    # txtdata returns a non- zone-file-format encoded result, unlike rdstring;
    # avoid space-separated RDATA <character-string> fields if possible,
    # txtdata provides a list of strings in a list context since Net::DNS 0.69
    $rdatastr = join('',$answer->txtdata);
  } else {
    # rdatastr() is historical/undocumented, use rdstring() since Net::DNS 0.69
    $rdatastr = $answer->UNIVERSAL::can('rdstring') ? $answer->rdstring
                                                    : $answer->rdatastr;
    # encoded in a RFC 1035 zone file format (escaped), decode it
    $rdatastr =~ s{ \\ ( [0-9]{3} | (?![0-9]{3}) . ) }
                  { length($1)==3 && $1 <= 255 ? chr($1) : $1 }xgse;
  }
  # Bug 7236: Net::DNS attempts to decode text strings in a TXT record as
  # UTF-8 since version 0.69, which is undesired: octets failing the UTF-8
  # decoding are converted to a Unicode "replacement character" U+FFFD, and
  # ASCII text is unnecessarily flagged as perl native characters.
  utf8::encode($rdatastr)  if utf8::is_utf8($rdatastr);

  while (my ($subtest, $rule) = each %{$self->{rbl_subs}{$set}}) {
    next if $self->{tests_already_hit}->{$rule};

    if ($subtest =~ /^\d+\.\d+\.\d+\.\d+$/) {
      # test for exact equality, not a regexp (an IPv4 address)
      $self->dnsbl_hit($rule, $question, $answer)  if $subtest eq $rdatastr;
    }
    # senderbase
    elsif ($subtest =~ s/^sb://) {
      # SB rules are not available to users
      if ($self->{conf}->{user_defined_rules}->{$rule}) {
        dbg("dns: skipping rule '$rule': not supported when user-defined");
        next;
      }

      $rdatastr =~ s/^\d+-//;
      my %sb = ($rdatastr =~ m/(?:^|\|)(\d+)=([^|]+)/g);
      my $undef = 0;
      while ($subtest =~ m/\bS(\d+)\b/g) {
	if (!defined $sb{$1}) {
	  $undef = 1;
	  last;
	}
	$subtest =~ s/\bS(\d+)\b/\$sb{$1}/;
      }

      # untaint. (bug 3325)
      $subtest = untaint_var($subtest);

      $self->got_hit($rule, "SenderBase: ", ruletype => "dnsbl") if !$undef && eval $subtest;
    }
    # bitmask
    elsif ($subtest =~ /^\d+$/) {
      # Bug 6803: response should be within 127.0.0.0/8, ignore otherwise
      if ($rdatastr =~ m/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/ &&
	  Mail::SpamAssassin::Util::my_inet_aton($rdatastr) & $subtest)
      {
	$self->dnsbl_hit($rule, $question, $answer);
      }
    }
    # regular expression
    else {
      my $test = qr/$subtest/;
      if ($rdatastr =~ /$test/) {
	$self->dnsbl_hit($rule, $question, $answer);
      }
    }
  }
}

sub harvest_until_rule_completes {
  my ($self, $rule) = @_;

  dbg("dns: harvest_until_rule_completes");
  my $result = 0;

  for (my $first=1;  ; $first=0) {
    # complete_lookups() may call completed_callback(), which may
    # call start_lookup() again (like in Plugin::URIDNSBL)
    my ($alldone,$anydone) =
      $self->{async}->complete_lookups($first ? 0 : 1.0,  1);

    $result = 1  if $self->is_rule_complete($rule);
    last  if $result || $alldone;

    dbg("dns: harvest_until_rule_completes - check_tick");
    $self->{main}->call_plugins ("check_tick", { permsgstatus => $self });
  }

  return $result;
}

sub harvest_dnsbl_queries {
  my ($self) = @_;

  dbg("dns: harvest_dnsbl_queries");

  for (my $first=1;  ; $first=0) {
    # complete_lookups() may call completed_callback(), which may
    # call start_lookup() again (like in Plugin::URIDNSBL)

    # the first time around we specify a 0 timeout, which gives
    # complete_lookups a chance to ripe any available results and
    # abort overdue requests, without needlessly waiting for more

    my ($alldone,$anydone) =
      $self->{async}->complete_lookups($first ? 0 : 1.0,  1);

    last  if $alldone || $self->{deadline_exceeded};

    dbg("dns: harvest_dnsbl_queries - check_tick");
    $self->{main}->call_plugins ("check_tick", { permsgstatus => $self });
  }

  # explicitly abort anything left
  $self->{async}->abort_remaining_lookups();
  $self->{async}->log_lookups_timing();
  1;
}

# collect and process whatever DNS responses have already arrived,
# don't waste time waiting for more, don't poll too often.
# don't abort any queries even if overdue, 
sub harvest_completed_queries {
  my ($self) = @_;

  # don't bother collecting responses too often
  my $last_poll_time = $self->{async}->last_poll_responses_time();
  return if defined $last_poll_time && time - $last_poll_time < 0.1;

  my ($alldone,$anydone) = $self->{async}->complete_lookups(0, 0);
  if ($anydone) {
    dbg("dns: harvested completed queries");
#   $self->{main}->call_plugins ("check_tick", { permsgstatus => $self });
  }
}

sub set_rbl_tag_data {
  my ($self) = @_;

  return if !$self->{dnsuri};

  # DNS URIs
  my $rbl_tag = $self->{tag_data}->{RBL};  # just in case, should be empty
  $rbl_tag = ''  if !defined $rbl_tag;
  while (my ($dnsuri, $answers) = each %{$self->{dnsuri}}) {
    # when parsing, look for elements of \".*?\" or \S+ with ", " as separator
    $rbl_tag .= "<$dnsuri>" . " [" . join(", ", keys %$answers) . "]\n";
  }
  if (defined $rbl_tag && $rbl_tag ne '') {
    chomp $rbl_tag;
    $self->set_tag('RBL', $rbl_tag);
  }
}

###########################################################################

sub init_rbl_subs {
  my ($self) = @_;

  if (!$self->{rbl_subs}) {
    foreach my $rule (@{$self->{conf}->{eval_to_rule}->{check_rbl_sub}}) {
      next if !exists $self->{conf}->{rbl_evals}->{$rule};
      next if !$self->{conf}->{scores}->{$rule};
      (undef, my @args) = @{$self->{conf}->{rbl_evals}->{$rule}};
      $self->{rbl_subs}{$args[0]}{$args[1]} = $rule;
    }
  }
}

sub rbl_finish {
  my ($self) = @_;

  $self->set_rbl_tag_data();

  delete $self->{rbl_subs};
  delete $self->{dnsuri};
}

###########################################################################

sub load_resolver {
  my ($self) = @_;
  $self->{resolver} = $self->{main}->{resolver};
  return $self->{resolver}->load_resolver();
}

sub clear_resolver {
  my ($self) = @_;
  dbg("dns: clear_resolver");
  $self->{main}->{resolver}->{res} = undef;
  return 0;
}

sub lookup_ns {
  my ($self, $dom) = @_;

  return unless $self->load_resolver();
  return if ($self->server_failed_to_respond_for_domain ($dom));

  my $nsrecords;
  dbg("dns: looking up NS for '$dom'");

  eval {
    my $query = $self->{resolver}->send($dom, 'NS');
    my @nses;
    if ($query) {
      foreach my $rr ($query->answer) {
        if ($rr->type eq "NS") { push (@nses, $rr->nsdname); }
      }
    }
    $nsrecords = [ @nses ];
    1;
  } or do {
    my $eval_stat = $@ ne '' ? $@ : "errno=$!";  chomp $eval_stat;
    dbg("dns: NS lookup failed horribly, perhaps bad resolv.conf setting? (%s)", $eval_stat);
    return;
  };

  $nsrecords;
}

sub is_dns_available {
  my ($self) = @_;
  my $dnsopt = $self->{conf}->{dns_available};

  # Fast response for the most common cases
  return 1 if $IS_DNS_AVAILABLE && $dnsopt eq "yes";
  return 0 if defined $IS_DNS_AVAILABLE && $dnsopt eq "no";

  # undef $IS_DNS_AVAILABLE if we should be testing for
  # working DNS and our check interval time has passed
  if ($dnsopt eq "test") {
    my $diff = time - $LAST_DNS_CHECK;
    if ($diff > ($self->{conf}->{dns_test_interval}||600)) {
      $IS_DNS_AVAILABLE = undef;
      if ($LAST_DNS_CHECK) {
        dbg("dns: is_dns_available() last checked %.1f seconds ago; re-checking", $diff);
      } else {
        dbg("dns: is_dns_available() initial check");
      }
    }
    $LAST_DNS_CHECK = time;
  }

  return $IS_DNS_AVAILABLE if defined $IS_DNS_AVAILABLE;

  $IS_DNS_AVAILABLE = 0;
  if ($dnsopt eq "no") {
    dbg("dns: dns_available set to no in config file, skipping test");
    return $IS_DNS_AVAILABLE;
  }

  # Even if "dns_available" is explicitly set to "yes", we want to ignore
  # DNS if we're only supposed to be looking at local tests.
  goto done if ($self->{main}->{local_tests_only});

  # Check version numbers - runtime check only
  if (defined $Net::DNS::VERSION) {
    if (am_running_on_windows()) {
      if ($Net::DNS::VERSION < 0.46) {
	warn("dns: Net::DNS version is $Net::DNS::VERSION, but need 0.46 for Win32");
	return $IS_DNS_AVAILABLE;
      }
    }
    else {
      if ($Net::DNS::VERSION < 0.34) {
	warn("dns: Net::DNS version is $Net::DNS::VERSION, but need 0.34");
	return $IS_DNS_AVAILABLE;
      }
    }
  }

  $self->clear_resolver();
  goto done unless $self->load_resolver();

  if ($dnsopt eq "yes") {
    # optionally shuffle the list of nameservers to distribute the load
    if ($self->{conf}->{dns_options}->{rotate}) {
      my @nameservers = $self->{resolver}->available_nameservers();
      Mail::SpamAssassin::Util::fisher_yates_shuffle(\@nameservers);
      dbg("dns: shuffled NS list: " . join(", ", @nameservers));
      $self->{resolver}->available_nameservers(@nameservers);
    }
    $IS_DNS_AVAILABLE = 1;
    dbg("dns: dns_available set to yes in config file, skipping test");
    return $IS_DNS_AVAILABLE;
  }

  my @domains;
  if ($dnsopt =~ /^test:\s*(\S.*)$/) {
    @domains = split (/\s+/, $1);
    dbg("dns: looking up NS records for user specified domains: %s",
        join(", ", @domains));
  } else {
    @domains = @EXISTING_DOMAINS;
    dbg("dns: looking up NS records for built-in domains");
  }

  # do the test with a full set of configured nameservers
  my @nameservers = $self->{resolver}->configured_nameservers();

  # optionally shuffle the list of nameservers to distribute the load
  if ($self->{conf}->{dns_options}->{rotate}) {
    Mail::SpamAssassin::Util::fisher_yates_shuffle(\@nameservers);
    dbg("dns: shuffled NS list, testing: " . join(", ", @nameservers));
  } else {
    dbg("dns: testing resolver nameservers: " . join(", ", @nameservers));
  }

  # Try the different nameservers here and collect a list of working servers
  my @good_nameservers;
  foreach my $ns (@nameservers) {
    $self->{resolver}->available_nameservers($ns);  # try just this one
    for (my $retry = 3; $retry > 0 && @domains; $retry--) {
      my $domain = splice(@domains, rand(@domains), 1);
      dbg("dns: trying ($retry) $domain, server $ns ...");
      my $result = $self->lookup_ns($domain);
      $self->{resolver}->finish_socket();
      if (!$result) {
        dbg("dns: NS lookup of $domain using $ns failed horribly, ".
            "may not be a valid nameserver");
        last;
      } elsif (!@$result) {
        dbg("dns: NS lookup of $domain using $ns failed, no results found");
      } else {
        dbg("dns: NS lookup of $domain using $ns succeeded => DNS available".
            " (set dns_available to override)");
        push(@good_nameservers, $ns);
        last;
      }
    }
  }

  if (!@good_nameservers) {
    dbg("dns: all NS queries failed => DNS unavailable ".
        "(set dns_available to override)");
  } else {
    $IS_DNS_AVAILABLE = 1;
    dbg("dns: NS list: ".join(", ", @good_nameservers));
    $self->{resolver}->available_nameservers(@good_nameservers);
  }

done:
  # jm: leaving this in!
  dbg("dns: is DNS available? " . $IS_DNS_AVAILABLE);
  return $IS_DNS_AVAILABLE;
}

###########################################################################

sub server_failed_to_respond_for_domain {
  my ($self, $dom) = @_;
  if ($self->{dns_server_too_slow}->{$dom}) {
    dbg("dns: server for '$dom' failed to reply previously, not asking again");
    return 1;
  }
  return 0;
}

sub set_server_failed_to_respond_for_domain {
  my ($self, $dom) = @_;
  dbg("dns: server for '$dom' failed to reply, marking as bad");
  $self->{dns_server_too_slow}->{$dom} = 1;
}

###########################################################################

sub enter_helper_run_mode {
  my ($self) = @_;

  dbg("dns: entering helper-app run mode");
  $self->{old_slash} = $/;              # Razor pollutes this
  %{$self->{old_env}} = ();
  if ( %ENV ) {
    # undefined values in %ENV can result due to autovivification elsewhere,
    # this prevents later possible warnings when we restore %ENV
    while (my ($key, $value) = each %ENV) {
      $self->{old_env}->{$key} = $value if defined $value;
    }
  }

  Mail::SpamAssassin::Util::clean_path_in_taint_mode();

  my $newhome;
  if ($self->{main}->{home_dir_for_helpers}) {
    $newhome = $self->{main}->{home_dir_for_helpers};
  } else {
    # use spamd -u user's home dir
    $newhome = (Mail::SpamAssassin::Util::portable_getpwuid ($>))[7];
  }

  if ($newhome) {
    $ENV{'HOME'} = Mail::SpamAssassin::Util::untaint_file_path ($newhome);
  }

  # enforce SIGCHLD as DEFAULT; IGNORE causes spurious kernel warnings
  # on Red Hat NPTL kernels (bug 1536), and some users of the
  # Mail::SpamAssassin modules set SIGCHLD to be a fatal signal
  # for some reason! (bug 3507)
  $self->{old_sigchld_handler} = $SIG{CHLD};
  $SIG{CHLD} = 'DEFAULT';
}

sub leave_helper_run_mode {
  my ($self) = @_;

  dbg("dns: leaving helper-app run mode");
  $/ = $self->{old_slash};
  %ENV = %{$self->{old_env}};

  if (defined $self->{old_sigchld_handler}) {
    $SIG{CHLD} = $self->{old_sigchld_handler};
  } else {
    # if SIGCHLD has never been explicitly set, it's returned as undef.
    # however, when *setting* SIGCHLD, using undef(%) or assigning to an
    # undef value produces annoying 'Use of uninitialized value in scalar
    # assignment' warnings.  That's silly.  workaround:
    $SIG{CHLD} = 'DEFAULT';
  }
}

# note: this must be called before leave_helper_run_mode() is called,
# as the SIGCHLD signal must be set to DEFAULT for it to work.
sub cleanup_kids {
  my ($self, $pid) = @_;
  
  if ($SIG{CHLD} && $SIG{CHLD} ne 'IGNORE') {	# running from spamd
    waitpid ($pid, 0);
  }
}

###########################################################################

# Deprecated async functions, everything is handled automatically
# now by bgsend .. $self->{async}->{pending_rules}
sub register_async_rule_start {}
sub register_async_rule_finish {}
sub mark_all_async_rules_complete {}

sub is_rule_complete {
  my ($self, $rule) = @_;

  return 1 if !exists $self->{async}->{pending_rules}{$rule};
  return 1 if !%{$self->{async}->{pending_rules}{$rule}};

  dbg("dns: $rule is not complete yet");
  return 0;
}

###########################################################################

1;
