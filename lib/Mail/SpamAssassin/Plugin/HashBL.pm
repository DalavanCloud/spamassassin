# <@LICENSE>
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to you under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at:
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

=head1 NAME

HashBL - query hashed (and unhashed) DNS blocklists

=head1 SYNOPSIS

  loadplugin Mail::SpamAssassin::Plugin::HashBL

  header   HASHBL_EMAIL eval:check_hashbl_emails('ebl.msbl.org')
  describe HASHBL_EMAIL Message contains email address found on EBL
  priority HASHBL_EMAIL -100 # required priority to launch async lookups

  body     HASHBL_BTC eval:check_hashbl_bodyre('btcbl.foo.bar', 'sha1/max=10/shuffle', '\b([13][a-km-zA-HJ-NP-Z1-9]{25,34})\b')
  describe HASHBL_BTC Message contains BTC address found on BTCBL
  priority HASHBL_BTC -100 # required priority to launch async lookups

=head1 DESCRIPTION

This plugin support multiple types of hashed or unhashed DNS blocklists.

OPTS refers to multiple generic options:

  raw      do not hash data, query as is
  md5      hash query with MD5
  sha1     hash query with SHA1
  sha256   hash query with SHA256
  case     keep case before hashing, default is to lowercase
  max=x	   maximum number of queries
  shuffle  if max exceeded, random shuffle queries before truncating to limit

Multiple options can be separated with slash or other non-word character. 
If OPTS is empty ('') or missing, default is used.

HEADERS referes to slash separated list of Headers to process:

  ALL           all headers
  ALLFROM       all From headers as returned by $pms->all_from_addrs()
  EnvelopeFrom  message envelope from (Return-Path etc)
  HeaderName    any header as used with $pms->get()

if HEADERS is empty ('') or missing, default is used.

=over 4

=item header RULE check_hashbl_emails('bl.example.com/A', 'OPTS', 'HEADERS/body', '^127\.')

Check email addresses from DNS list, "body" can be specified along with
headers to search body for emails.  Optional subtest regexp to match DNS
answer.  Note that eval rule type must always be "header".

DNS query type can be appended to list with /A (default) or /TXT.

Additional supported OPTS:

  nodot    strip username dots from email
  notag    strip username tags from email
  nouri    ignore emails inside uris
  noquote  ignore emails inside < > or possible quotings

Default OPTS: sha1/notag/noquote/max=10/shuffle

Default HEADERS: ALLFROM/Reply-To/body

For existing public email blacklist, see: http://msbl.org/ebl.html

  header HASHBL_EBL check_hashbl_emails('ebl.msbl.org')
  priority HASHBL_EBL -100 # required for async query

=item body RULE check_hashbl_bodyre('bl.example.com/A', 'OPTS', '\b(match)\b', '^127\.')

Search body for matching regexp and query the string captured.  Regexp must
have a single capture ( ) for the string ($1).  Optional subtest regexp to
match DNS answer.  Note that eval rule type must be "body" or "rawbody".

Default OPTS: sha1/max=10/shuffle

=item hashbl_ignore string string2 ...

Ignore (do not query) specified emails or captured strings.
Both raw and hashed values are checked.

=back

=cut

package Mail::SpamAssassin::Plugin::HashBL;
my $VERSION = 0.100;

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use Digest::SHA qw(sha1_hex sha256_hex);

use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::Util;

our @ISA = qw(Mail::SpamAssassin::Plugin);

sub dbg {
  my $msg = shift;
  Mail::SpamAssassin::Plugin::dbg("HashBL: $msg", @_);
}

sub new {
  my ($class, $mailsa) = @_;

  $class = ref($class) || $class;
  my $self = $class->SUPER::new($mailsa);
  bless ($self, $class);

  # are network tests enabled?
  if ($mailsa->{local_tests_only}) {
    $self->{hashbl_available} = 0;
    dbg("local tests only, disabling HashBL");
  } else {
    $self->{hashbl_available} = 1;
  }

  $self->register_eval_rule("check_hashbl_emails");
  $self->register_eval_rule("check_hashbl_bodyre");
  $self->set_config($mailsa->{conf});

  return $self;
}

sub set_config {
  my($self, $conf) = @_;
  my @cmds;

  push (@cmds, {
    setting => 'hashbl_ignore',
    is_admin => 1,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_HASH_KEY_VALUE,
    default => {},
    code => sub {
      my ($self, $key, $value, $line) = @_;
      if (!defined $value || $value eq '') {
        return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
      }
      foreach my $str (split (/\s+/, $value)) {
        $self->{hashbl_ignore}->{lc $str} = 1;
      }
    }
  });

  $conf->{parser}->register_commands(\@cmds);
}

sub finish_parsing_end {
  my ($self, $opts) = @_;

  return 0 if !$self->{hashbl_available};

  # valid_tlds_re will be available at finish_parsing_end, compile it now,
  # we only need to do it once and before possible forking
  if (!exists $self->{email_re}) {
    $self->_init_email_re();
  }

  return 0;
}

sub _init_email_re {
  my ($self) = @_;

  # Some regexp tips courtesy of http://www.regular-expressions.info/email.html
  # full email regex v0.02
  $self->{email_re} = qr/
    (?=.{0,64}\@)			# limit userpart to 64 chars (and speed up searching?)
    (?<![a-z0-9!#\$%&'*+\/=?^_`{|}~-])	# start boundary
    (					# capture email
    [a-z0-9!#\$%&'*+\/=?^_`{|}~-]+	# no dot in beginning
    (?:\.[a-z0-9!#\$%&'*+\/=?^_`{|}~-]+)* # no consecutive dots, no ending dot
    \@
    (?:[a-z0-9](?:[a-z0-9-]{0,59}[a-z0-9])?\.){1,4} # max 4x61 char parts (should be enough?)
    $self->{main}->{registryboundaries}->{valid_tlds_re} # ends with valid tld
    )
  /xi;
}

sub _get_emails {
  my ($self, $pms, $opts, $from) = @_;

  my @emails; # keep find order
  my %seen;
  foreach my $hdr (split(/\W+/, $from)) {
    my $parsed_emails = $self->_parse_emails($pms, $opts, $hdr);
    foreach (@$parsed_emails) {
      next if exists $seen{$_};
      push @emails, $_;
      $seen{$_} = 1;
    }
  }

  return \@emails;
}

sub _parse_emails {
  my ($self, $pms, $opts, $hdr) = @_;

  if (exists $pms->{hashbl_email_cache}{$hdr}) {
    return $pms->{hashbl_email_cache}{$hdr};
  }

  if ($hdr eq 'ALLFROM') {
    my @emails = $pms->all_from_addrs();
    return $pms->{hashbl_email_cache}{$hdr} = \@emails;
  }

  my $str = '';
  if ($hdr eq 'ALL') {
    $str = join("\n", $pms->get('ALL'));
  } elsif ($hdr eq 'body') {
    # get all <a href="mailto:", since they don't show up on stripped_body
    my $uris = $pms->get_uri_detail_list();
    while (my($uri, $info) = each %{$uris}) {
      if (defined $info->{types}->{a} && !defined $info->{types}->{parsed}) {
        if ($uri =~ /^mailto:(.+)/i) {
          $str .= "$1\n";
        }
      }
    }
    my $body = join('', $pms->get_decoded_stripped_body_text_array());
    if ($opts =~ /\bnouri\b/) {
      # strip urls with possible emails inside
      $body =~ s#<?https?://\S{0,255}(?:\@|%40)\S{0,255}# #gi;
    }
    if ($opts =~ /\bnoquote\b/) {
      # strip emails contained in <>, not mailto:
      # also strip ones followed by quote-like "wrote:" (but not fax: and tel: etc)
      $body =~ s#<?(?<!mailto:)$self->{email_re}(?:>|\s{1,10}(?!(?:fa(?:x|csi)|tel|phone|e?-?mail))[a-z]{2,11}:)# #gi;
    }
    $str .= $body;
  } else {
    $str .= join("\n", $pms->get($hdr));
  }

  my @emails; # keep find order
  my %seen;
  while ($str =~ /($self->{email_re})/g) {
    next if exists $seen{$1};
    push @emails, $1;
  }

  return $pms->{hashbl_email_cache}{$hdr} = \@emails;
}

sub check_hashbl_emails {
  my ($self, $pms, $list, $opts, $from, $subtest) = @_;

  return 0 if !$self->{hashbl_available};
  return 0 if !$self->{email_re};

  my $rulename = $pms->get_current_eval_rule_name();

  if (!defined $list) {
    info("HashBL: $rulename blocklist argument missing");
    return 0;
  }

  if ($subtest && !eval { $subtest = qr/$subtest/ }) {
    info("HashBL: $rulename invalid subtest regex: $@");
    return 0;
  }

  # Defaults
  $opts = 'sha1/notag/noquote/max=10/shuffle' if !$opts;

  $from = 'ALLFROM/Reply-To/body' if !$from;

  # Find all emails
  my $emails = $self->_get_emails($pms, $opts, $from);
  if (!@$emails) {
    dbg("$rulename: no emails found ($from)");
    return 0;
  } else {
    dbg("$rulename: raw emails found: ".join(', ', @$emails));
  }

  # Filter list
  my $keep_case = $opts =~ /\bcase\b/i;
  my $nodot = $opts =~ /\bnodot\b/i;
  my $notag = $opts =~ /\bnotag\b/i;
  my @filtered_emails; # keep order
  my %seen;
  foreach my $email (@$emails) {
    next if exists $seen{$email};
    if ($nodot || $notag) {
      my ($username, $domain) = ($email =~ /(.*)(\@.*)/);
      $username =~ tr/.//d if $nodot;
      $username =~ s/\+.*// if $notag;
      $email = $username.$domain;
    }
    push @filtered_emails, $keep_case ? $email : lc($email);
    $seen{$email} = 1;
  }

  # Randomize order
  if ($opts =~ /\bshuffle\b/) {
    Mail::SpamAssassin::Util::fisher_yates_shuffle(\@filtered_emails);
  }

  # Truncate list
  my $max = $opts =~ /\bmax=(\d+)\b/ ? $1 : 10;
  $#filtered_emails = $max if scalar @filtered_emails > $max;

  foreach my $email (@filtered_emails) {
    $self->_submit_query($pms, $rulename, $email, $list, $opts, $subtest);
  }

  return 0;
}

sub check_hashbl_bodyre {
  my ($self, $pms, $bodyref, $list, $opts, $re, $subtest) = @_;

  return 0 if !$self->{hashbl_available};

  my $rulename = $pms->get_current_eval_rule_name();

  if (!defined $list) {
    info("HashBL: $rulename blocklist argument missing");
    return 0;
  }

  if (!$re || !eval { $re = qr/$re/ }) {
    info("HashBL: $rulename invalid body regex: $@");
    return 0;
  }

  if ($subtest && !eval { $subtest = qr/$subtest/ }) {
    info("HashBL: $rulename invalid subtext regex: $@");
    return 0;
  }

  # Defaults
  $opts = 'sha1/max=10/shuffle' if !$opts;

  my $keep_case = $opts =~ /\bcase\b/i;

  # Search body
  my @matches;
  my %seen;
  if (ref($bodyref) eq 'ARRAY') {
    # body, rawbody
    foreach (@$bodyref) {
      while ($_ =~ /$re/gs) {
        next if !defined $1;
        my $match = $keep_case ? $1 : lc($1);
        next if exists $seen{$match};
        $seen{$match} = 1;
        push @matches, $match;
      }
    }
  } else {
    # full
    while ($$bodyref =~ /$re/gs) {
      next if !defined $1;
      my $match = $keep_case ? $1 : lc($1);
      next if exists $seen{$match};
      $seen{$match} = 1;
      push @matches, $match;
    }
  }

  if (!@matches) {
    dbg("$rulename: no matches found");
    return 0;
  } else {
    dbg("$rulename: matches found: '".join("', '", @matches)."'");
  }

  # Randomize order
  if ($opts =~ /\bshuffle\b/) {
    Mail::SpamAssassin::Util::fisher_yates_shuffle(\@matches);
  }

  # Truncate list
  my $max = $opts =~ /\bmax=(\d+)\b/ ? $1 : 10;
  $#matches = $max if scalar @matches > $max;

  foreach my $match (@matches) {
    $self->_submit_query($pms, $rulename, $match, $list, $opts, $subtest);
  }

  return 0;
}

sub _hash {
  my ($self, $opts, $value) = @_;

  my $hashtype = $opts =~ /\b(raw|sha1|sha256|md5)\b/i ? lc($1) : 'sha1';
  if ($hashtype eq 'sha1') {
    return sha1_hex($value);
  } elsif ($hashtype eq 'sha256') {
    return sha256_hex($value);
  } elsif ($hashtype eq 'md5') {
    return md5_hex($value);
  } else {
    return $value;
  }
}

sub _submit_query {
  my ($self, $pms, $rulename, $value, $list, $opts, $subtest) = @_;

  if (exists $pms->{conf}->{hashbl_ignore}->{lc $value}) {
    dbg("query skipped, ignored string: $value");
    return 1;
  }

  my $hash = $self->_hash($opts, $value);
  dbg("querying $value ($hash) from $list");

  if (exists $pms->{conf}->{hashbl_ignore}->{$hash}) {
    dbg("query skipped, ignored hash: $value");
    return 1;
  }

  my $type = $list =~ s,/(A|TXT)$,,i ? uc($1) : 'A';
  my $lookup = "$hash.$list";

  my $ent = {
    rulename => $rulename,
    type => "HASHBL",
    hash => $hash,
    value => $value,
    subtest => $subtest,
  };
  $pms->{async}->bgsend_and_start_lookup($lookup, $type, undef, $ent,
    sub { my ($ent, $pkt) = @_; $self->_finish_query($pms, $ent, $pkt); },
    master_deadline => $pms->{master_deadline}
  );
}

sub _finish_query {
  my ($self, $pms, $ent, $pkt) = @_;

  if (!$pkt) {
    # $pkt will be undef if the DNS query was aborted (e.g. timed out)
    dbg("lookup was aborted: $ent->{rulename} $ent->{key}");
    return;
  }

  my $dnsmatch = $ent->{subtest} ? $ent->{subtest} : qr/^127\./;
  my @answer = $pkt->answer;
  foreach my $rr (@answer) {
    if ($rr->address =~ $dnsmatch) {
      dbg("$ent->{rulename}: $ent->{zone} hit '$ent->{value}'");
      $ent->{value} =~ s/\@/[at]/g;
      $pms->test_log($ent->{value});
      $pms->got_hit($ent->{rulename}, '', ruletype => 'eval');
      return;
    }
  }
}

# Version features
sub has_hashbl_bodyre { 1 }
sub has_hashbl_ignore { 1 }

1;
