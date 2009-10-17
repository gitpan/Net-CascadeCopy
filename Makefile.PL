
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  DISTNAME  => 'Net-CascadeCopy',
  NAME      => 'Net::CascadeCopy',
  AUTHOR    => 'Alex\ White\ \<VVu\@geekfarm\.org\>',
  ABSTRACT  => 'Rapidly\ propagate\ \(rsync\/scp\/\.\.\.\)\ files\ to\ many\ servers\ in\ multiple\ locations\.',
  VERSION   => '0.2.3',
  EXE_FILES => [ qw(bin/ccp) ],
  (eval { ExtUtils::MakeMaker->VERSION(6.31) } ? (LICENSE => 'bsd') : ()),
  PREREQ_PM    => {
    "Getopt::Long" => '0',
    "Pod::Usage" => '0',
    "Benchmark" => '0',
    "Data::Dumper" => '0',
    "vars" => '0',
    "Proc::Queue" => '0',
    "Test::More" => '0',
    "Class::Std::Utils" => '0',
    "POSIX" => '0',
    "Log::Log4perl" => '0',
  },
  test => {TESTS => 't/*.t'}
);

