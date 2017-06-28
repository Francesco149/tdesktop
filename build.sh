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

        # TODO: busybox doesn't hold the exit code unless
        # you call wait before the process terminates,
        # so we end up getting
        # 127 = already terminated
        # which doesn't help figuring out if the process
        # errored or not.
        # find out a portable way to do this
        if [ $retcode != 0 ] && [ $retcode != 127 ]
        then
            echo "job $pid failed with code $retcode"
            echo "Check 'out/build.log' for more details"
            cat out/tmp.* >> out/build.log
            exit $retcode
        fi
        pids=$(echo $pids | cut -d"," -f2-)
    done
}

handle_sigint() {
    echo "Caught SIGINT, killing jobs..."
    while [ true ]
    do
        pid=$(echo $pids | cut -d"," -f1-1)
        [ -z $pid ] && break
        kill -INT $pid
        wait $pid
        pids=$(echo $pids | cut -d"," -f2-)
    done
}

trap handle_sigint SIGINT

# -----------------------------------------------------------------

rm -rf out
mkdir -p out

echo "Build started on $(date)" > out/build.log

starttime=$(date +"%s")

cxx=${CXX:-g++}

# first of all, we build the codegen's. these will be used to
# generate code for localization, emoji, and other stuff.

cxxflags="-std=c++14 -pipe -Wall -fPIC"
cxxflags="$cxxflags -ITelegram/SourceFiles"
cxxflags="$cxxflags $CXXFLAGS"

# -----------------------------------------------------------------

b=Telegram/SourceFiles/codegen

# lang and numbers codegens didn't actually need Qt5Gui
# the devs simply forgot to remove the QtImage include they
# copypasted
pkgs="Qt5Core"
pkgflags="$(pkg-config --cflags $pkgs)"
pkglibs="$(pkg-config --libs $pkgs)"

for type in lang numbers
do
    exe="out/codegen_${type}"

    job() {
        echo $exe

        $cxx \
          $cxxflags \
          $pkgflags \
          "$b/common/"*.cpp \
          "$b/$type/"*.cpp \
          $pkglibs \
          -o "$exe"
    }

    addjob job
done

# emoji actually uses Qt5Gui
pkgs="Qt5Core Qt5Gui"
pkgflags="$(pkg-config --cflags $pkgs)"
pkglibs="$(pkg-config --libs $pkgs)"

for type in emoji style
do
    exe="out/codegen_${type}"

    job() {
        echo $exe

        $cxx \
          $cxxflags \
          $pkgflags \
          "$b/common/"*.cpp \
          "$b/$type/"*.cpp \
          $pkglibs \
          -o "$exe"
    }

    addjob job
done

join
cat out/tmp.* >> out/build.log
rm out/tmp.*

# -----------------------------------------------------------------

b="Telegram/Resources"

codegenjob() {
  echo "Generating langs"
  out/codegen_lang -o out "$b"/langs/lang.strings

  echo "Generating numbers"
  out/codegen_numbers -o out "$b"/numbers.txt

  echo "Generating emoji"
  out/codegen_emoji -o out
}

addjob codegenjob

stylejob() {
    find Telegram -name "*.style" | while read style
    do
        echo "$style"
        out/codegen_style \
          -I "$b" \
          -I Telegram/SourceFiles \
          -o out/styles \
          "$style"
    done
}

addjob stylejob

schemejob() {
    echo "Generating scheme"
    codegen_scheme_dir=Telegram/SourceFiles/codegen/scheme
    python $codegen_scheme_dir/codegen_scheme.py \
      -o out \
      "$b"/scheme.tl
}

addjob schemejob

# -----------------------------------------------------------------

# QT uses special metaprogramming syntax that needs to be handled
# by moc, which will generate an additional cpp file

b=Telegram/SourceFiles

run_moc() {
    for file in $@
    do
        echo "moc'ing $file"
        prefix="$(dirname "$file")"
        mkdir -p "out/moc/$prefix"
        dstfile=out/moc/"$prefix"/moc_"$(basename $file)".cpp
        moc --no-notes "$file" -o "$dstfile"
        [ $(wc -c < "$dstfile") -eq 0 ] && rm "$dstfile"
    done

    return 0
}

addjob run_moc "$b"/*.cpp "$b"/*.h

for dirname in base boxes calls core chat_helpers data dialogs \
               history inline_bots intro media mtproto overview \
               platform/linux profile settings storage ui window
do
    addjob run_moc "$b"/$dirname/*.cpp "$b"/$dirname/*.h
done

# -----------------------------------------------------------------

# resource files are compiled to hardcoded cpp files by qt's rcc

b="Telegram/Resources/qrc"

run_rcc() {
    for file in $@
    do
        echo "rcc'ing $file"
        mkdir -p "out/qrc"
        filename=$(basename "$file")
        filename_noext=$(echo $filename | rev | cut -d"." -f2- | rev)

        rcc \
          -no-compress \
          -name $filename_noext \
          "$file" \
          -o "out/qrc/qrc_$filename_noext.cpp"
    done
}

addjob run_rcc "$b"/*.qrc

join
cat out/tmp.* >> out/build.log
rm out/tmp.*

# -----------------------------------------------------------------

# TODO: compile rest

# -----------------------------------------------------------------

endtime=$(date +"%s")
diff=$(expr $endtime - $starttime)
mins=$(expr $diff / 60)
secs=$(expr $diff % 60)

timemsg="Time spent: ${mins}m ${secs}s"
echo $timemsg >> out/build.log

echo ""
echo $timemsg
echo "Check 'out/build.log' for more details"
