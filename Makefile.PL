use 5.018000;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME              => 'IRC::Logger',
    VERSION_FROM      => 'lib/IRC/Logger.pm',
    PREREQ_PM         => {},
    ($] >= 5.005 ?
      (ABSTRACT_FROM  => 'lib/IRC/Logger.pm',
       AUTHOR         => 'Tooru Iwasaki <rockbone.g@gmail.com>') : ()),
);
