/*
	read_versions
	Output all way and node versions from an .osm.pbf as CSVs

	First generate protobuf headers:
	protoc osmformat.proto --cpp_out=.

	To compile:
	clang++ -o read_versions osmformat.pb.cc read_versions.cpp -std=c++11 -lz `pkg-config --cflags --libs protobuf`
	(or g++ for Linux systems)

	Then to run:
	./read_versions greater-london-latest.osm.pbf
*/

#include <iostream>
#include <fstream>
#include "osmformat.pb.h"

using namespace std;
#include "helpers.cpp"
#include "pbf_blocks.cpp"

int main(int argc, char* argv[]) {

	fstream inFile(argv[1], ios::in | ios::binary);
	if (!inFile) { cerr << "Couldn't open .pbf input file." << endl; return -1; }

	ofstream wayFile; wayFile.open("way_versions.csv");
	ofstream nodeFile; nodeFile.open("node_versions.csv");

	HeaderBlock block;
	readBlock(&block, &inFile);

	PrimitiveBlock pb;
	PrimitiveGroup pg;
	DenseNodes dense;
	Way pbfWay;
	unsigned long nodeId;

	while (!inFile.eof()) {
		readBlock(&pb, &inFile);
		for (uint i=0; i<pb.primitivegroup_size(); i++) {
			pg = pb.primitivegroup(i);

			// Read ways
			for (uint j=0; j<pg.ways_size(); j++) {
				pbfWay = pg.ways(j);
				wayFile << pbfWay.id() << "," << pbfWay.info().version() << endl;
			}

			// Read nodes
			nodeId  = 0;
			dense = pg.dense();
			for (uint j=0; j<dense.id_size(); j++) {
				nodeId += dense.id(j);
				nodeFile << nodeId << "," << dense.denseinfo().version(j) << endl;
			}
		}
	}

	inFile.close();
	wayFile.close();
	nodeFile.close();
	google::protobuf::ShutdownProtobufLibrary();
}
