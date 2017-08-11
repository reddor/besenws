#!/bin/bash

DEFAULTPARAMS="-Fusrc/besen -Fusrc/synapse -FE."
DYNAMICPARAMS="-O3"

if [ ! -f src/besenws.pas ] 
then
	echo "File not found or script not called in right directory"
	exit 1
fi

if [ "$#" -eq 1 ]
then
	if [[ "$1" = "debug" ]]; then
		DYNAMICPARAMS="-O1 -g -gl -gh -B"
	elif [[ "$1" = "clean" ]]; then
		echo "Cleaning..."
		rm -rf *.o
		rm -rf *.ppu
		exit 0
	elif [[ "$1" = "build" ]]; then
		DYNAMICPARAMS="-B"
	else
		echo "Valid commands: debug, clean"
		exit 1
	fi
fi

fpc $DEFAULTPARAMS $DYNAMICPARAMS src/besenws.pas
