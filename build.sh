#!/bin/sh

# TODO: *maybe* make a makefile when I know how every part of the
#       build works

# -----------------------------------------------------------------
# just some rudimentary parallel job manager

threads=${MAKE_THREADS:-9}
pids=""

addjob() {
    while [ true ]
    do
        # trim completed processes off pids
        tmp=$pids
        newpids=""
        while [ true ]
        do
            pid=$(echo $tmp | cut -d"," -f1-1)
            [ -z $pid ] && break
            kill -0 $pid && newpids=$pid,$newpids
            tmp=$(echo $tmp | cut -d"," -f2-)
        done

        pids=$newpids

        # wait until there's room for new jobs
        if [ $(echo $pids | grep -o "," | wc -l) -ge $threads ]
        then
            sleep 0.1
        else
            break
        fi
    done

    $@ 2>&1 > "$(mktemp -p out -u tmp.XXXXXX)" &
    pids=$!,$pids
}

join() {
    while [ true ]
    do
        pid=$(echo $pids | cut -d"," -f1-1)
        [ -z $pid ] && break
        wait $pid
        retcode=$?

        # 127 = already terminated
        if [ $retcode != 0 ] && [ $retcode != 127 ]
        then
            echo "job $pid failed with code $retcode"
            cat out/tmp.*
            exit $retcode
        fi
        pids=$(echo $pids | cut -d"," -f2-)
    done
}

# -----------------------------------------------------------------

rm -rf out
mkdir -p out

cxx=${CXX:-g++}
sourcedir="Telegram/SourceFiles"

# first of all, we build the codegen's. these will be used to
# generate code for localization, emoji, and other stuff.

cxxflags="-std=c++14 -pipe -Wall -fPIC -I$sourcedir $CXXFLAGS"
b="$sourcedir/codegen"

# lang and numbers codegens didn't actually need Qt5Gui
# the devs simply forgot to remove the QtImage include they
# copypasted
pkgs="Qt5Core"
pkgflags="$(pkg-config --cflags $pkgs)"
pkglibs="$(pkg-config --libs $pkgs)"

for type in lang numbers
do
    exe="out/codegen_${type}"
    echo $exe

    addjob \
    $cxx \
      $cxxflags \
      $pkgflags \
      "$b/common/"*.cpp \
      "$b/$type/"*.cpp \
      $pkglibs \
      -o "$exe"
done

# emoji actually uses Qt5Gui
pkgs="Qt5Core Qt5Gui"
pkgflags="$(pkg-config --cflags $pkgs)"
pkglibs="$(pkg-config --libs $pkgs)"

for type in emoji style
do
    exe="out/codegen_${type}"
    echo $exe

    addjob \
    $cxx \
      $cxxflags \
      $pkgflags \
      "$b/common/"*.cpp \
      "$b/$type/"*.cpp \
      $pkglibs \
      -o "$exe"
done

join
cat out/tmp.*
rm out/tmp.*

# -----------------------------------------------------------------

# TODO: run codegens
# TODO: run moc, rcc, ...
# TODO: compile rest

