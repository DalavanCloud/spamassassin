#
# RSA's SHA-1 in perl5 - "Fast" version.
#
# Usage:
#	$sha = sha1($data);
#
# Test Case:
#	$sha = sha1("squeamish ossifrage\n");
#	print $sha;
#	820550664cf296792b38d1647a4d8c0e1966af57
#
# This code is written for perl5, specifically any perl version after 5.002.
#
# This version has been somewhat optimized for speed, and gets about
# 10 KB per second on a PPC604-120 42T workstation running AIX.  Still
# pitiful compared with C.  Feel free to improve it if you can.
#
# Disowner:
#   This original perl implementation of RSADSI's SHA-1 was written by
#   John L. Allen, allen@gateway.grumman.com on 03/08/97.  No copyright
#   or property rights are claimed or implied.  You may use, copy, modify
#   and re-distribute it in any way you see fit, for personal or business
#   use, for inclusion in any free or for-profit product, royalty-free
#   and with no further obligation to the author.
#
# (2002 Daniel Quinlan: adapted public domain code into a module)

# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

package Mail::SpamAssassin::SHA1;

require 5.002;
use strict;
use bytes;
use integer;

use vars qw(
  @ISA @EXPORT
);

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw(sha1 sha1_hex);

use constant HAS_DIGEST_SHA1 => eval { require Digest::SHA1; };

sub sha1 {
  my ($data) = @_;

  if (HAS_DIGEST_SHA1) {
    # this is about 40x faster than the below perl version
    return Digest::SHA1::sha1($data);
  }
  else {
    return perl_sha1($data);
  }
}

sub sha1_hex {
  my ($data) = @_;
  return unpack("H40", sha1($data));
}

sub perl_sha1($) {

local $^W = 0;
local $_;
my @a = (16..19); my @b = (20..39); my @c = (40..59); my @d = (60..79);
my $data = $_[0];
my $aa = 0x67452301; my $bb = 0xefcdab89; my $cc = 0x98badcfe;
my $dd = 0x10325476; my $ee = 0xc3d2e1f0;
my ($a, $b, $c, $d, $e, $t, $l, $r, $p) = (0)x9;
my @W;

do {
  $_ = substr $data, $l, 64;
  $l += ($r = length);
  $r++, $_.="\x80" if ($r<64 && !$p++);	# handle padding, but once only ($p)
  @W = unpack "N16", $_."\0"x7;		# unpack block into array of 16 ints
  $W[15] = $l*8 if ($r<57);		# bit length of file in final block

	# initialize working vars from the accumulators

  $a=$aa, $b=$bb, $c=$cc, $d=$dd, $e=$ee;

	# the meat of SHA is 80 iterations applied to the working vars

  for(@W){
    $t = ($b&($c^$d)^$d)	+ $e + $_ + 0x5a827999 + ($a<<5|31&$a>>27);
    $e = $d; $d = $c; $c = $b<<30 | 0x3fffffff & $b>>2; $b = $a; $a = $t;
  }
  for(@a){
    $t = $W[$_-3]^$W[$_-8]^$W[$_-14]^$W[$_-16];
    $W[$_] = $t = ($t<<1|1&$t>>31);
    $t += ($b&($c^$d)^$d)	+ $e + 0x5a827999 + ($a<<5|31&$a>>27);
    $e = $d; $d = $c; $c = $b<<30 | 0x3fffffff & $b>>2; $b = $a; $a = $t;
  }
  for(@b){
    $t = $W[$_-3]^$W[$_-8]^$W[$_-14]^$W[$_-16];
    $W[$_] = $t = ($t<<1|1&$t>>31);
    $t += ($b^$c^$d)		+ $e + 0x6ed9eba1 + ($a<<5|31&$a>>27);
    $e = $d; $d = $c; $c = $b<<30 | 0x3fffffff & $b>>2; $b = $a; $a = $t;
  }
  for(@c){
    $t = $W[$_-3]^$W[$_-8]^$W[$_-14]^$W[$_-16];
    $W[$_] = $t = ($t<<1|1&$t>>31);
    $t += ($b&$c|($b|$c)&$d)	+ $e + 0x8f1bbcdc + ($a<<5|31&$a>>27);
    $e = $d; $d = $c; $c = $b<<30 | 0x3fffffff & $b>>2; $b = $a; $a = $t;
  }
  for(@d){
    $t = $W[$_-3]^$W[$_-8]^$W[$_-14]^$W[$_-16];
    $W[$_] = $t = ($t<<1|1&$t>>31);
    $t += ($b^$c^$d)		+ $e + 0xca62c1d6 + ($a<<5|31&$a>>27);
    $e = $d; $d = $c; $c = $b<<30 | 0x3fffffff & $b>>2; $b = $a; $a = $t;
  }

	# add in the working vars to the accumulators, modulo 2**32

  $aa+=$a, $bb+=$b, $cc+=$c, $dd+=$d, $ee+=$e;

} while $r>56;

my $bits = '';
vec($bits, 0, 32) = $aa;
vec($bits, 1, 32) = $bb;
vec($bits, 2, 32) = $cc;
vec($bits, 3, 32) = $dd;
vec($bits, 4, 32) = $ee;
return $bits;
}

1;
