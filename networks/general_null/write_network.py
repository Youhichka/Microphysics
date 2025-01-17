#!/usr/bin/env python3

import sys
import argparse

class Species:
    """the species class holds the properties of a single species"""
    def __init__(self):
        self.name = ""
        self.short_name = ""
        self.A = -1
        self.Z = -1

    def __str__(self):
        return "species {}, (A,Z) = {},{}".format(self.name, self.A, self.Z)

class AuxVar:
    """convenience class for an auxilliary variable"""
    def __init__(self):
        self.name = ""
        self.preprocessor = None

    def __str__(self):
        return "auxillary variable {}".format(self.name)

class UnusedVar:
    """this is what we return if an Aux var doesn't meet the preprocessor requirements"""
    def __init__(self):
        pass


def get_next_line(fin):
    """get_next_line returns the next, non-blank line, with comments
    stripped"""
    line = fin.readline()

    pos = str.find(line, "#")

    while (pos == 0 or str.strip(line) == "") and line:
        line = fin.readline()
        pos = str.find(line, "#")

    line = line[:pos]

    return line


def get_object_index(objs, name):
    """look through the list and returns the index corresponding to the
    network object (species or auxvar) specified by name

    """

    index = -1

    for n, o in enumerate(objs):
        if o.name == name:
            index = n
            break

    return index


def parse_net_file(species, aux_vars, net_file, defines):
    """parse_net_file read all the species listed in a given network
    inputs file and adds the valid species to the species list

    """

    err = 0

    try:
        f = open(net_file, "r")
    except IOError:
        sys.exit("write_network.py: ERROR: file "+str(net_file)+" does not exist")


    print("write_network.py: working on network file "+str(net_file)+"...")

    line = get_next_line(f)

    while line and not err:

        fields = line.split()

        # read the species or auxiliary variable from the line
        net_obj, err = parse_network_object(fields, defines)
        if net_obj is None:
            return err

        if isinstance(net_obj, UnusedVar):
            line = get_next_line(f)
            continue

        objs = species
        if isinstance(net_obj, AuxVar):
            objs = aux_vars

        # check to see if this species/auxvar is defined in the current list
        index = get_object_index(objs, net_obj.name)

        if index >= 0:
            print("write_network.py: ERROR: {} already defined.".format(net_obj))
            err = 1
        # add the species or auxvar to the appropriate list
        objs.append(net_obj)

        line = get_next_line(f)

    return err


def parse_network_object(fields, defines):
    """parse the fields in a line of the network file for either species
    or auxiliary variables.  Aux variables are prefixed by '__aux_' in
    the network file

    """

    err = 0

    # check for aux variables first
    if fields[0].startswith("__aux_"):
        ret = AuxVar()
        ret.name = fields[0][6:]
        # we can put a preprocessor variable after the aux name to require that it be
        # set in order to define the auxillary variable
        try:
            ret.preprocessor = fields[1]
        except IndexError:
            ret.preprocessor = None

        # we can put a preprocessor variable after the aux name to
        # require that it be set in order to define the auxillary
        # variable
        try:
            ret.preprocessor = fields[1]
        except IndexError:
            ret.preprocessor = None

        # if there is a preprocessor attached to this variable, then
        # we will check if we have defined that
        if ret.preprocessor is not None:
            if f"-D{ret.preprocessor }" not in defines:
                ret = UnusedVar()

        # we can put a preprocessor variable after the aux name to
        # require that it be set in order to define the auxillary
        # variable
        try:
            ret.preprocessor = fields[1]
        except IndexError:
            ret.preprocessor = None

        # if there is a preprocessor attached to this variable, then
        # we will check if we have defined that
        if ret.preprocessor is not None:
            if f"-D{ret.preprocessor }" not in defines:
                ret = UnusedVar()

    # check for missing fields in species definition
    elif not len(fields) == 4:
        print(" ".join(fields))
        print("write_network.py: ERROR: missing one or more fields in species definition.")
        ret = None
        err = 1
    else:
        ret = Species()

        ret.name = fields[0]
        ret.short_name = fields[1]
        ret.A = float(fields[2])
        ret.Z = float(fields[3])

    return ret, err


def abort(outfile):
    """exit when there is an error.  A dummy stub file is written out,
    which will cause a compilation failure

    """

    fout = open(outfile, "w")
    fout.write("There was an error parsing the network files")
    fout.close()
    sys.exit(1)



def write_network(network_template, header_template,
                  net_file, properties_file,
                  network_file, header_file, defines):
    """read through the list of species and output the new out_file

    """

    species = []
    aux_vars = []


    #-------------------------------------------------------------------------
    # read the species defined in the net_file
    #-------------------------------------------------------------------------
    err = parse_net_file(species, aux_vars, net_file, defines)

    if err:
        abort(network_file)


    properties = {}
    try:
        with open(properties_file) as f:
            for line in f:
                if line.strip() == "":
                    continue
                key, value = line.strip().split(":=")
                properties[key.strip()] = value.strip()
    except FileNotFoundError:
        print("no NETWORK_PROPERTIES found, skipping...")



    #-------------------------------------------------------------------------
    # write out the Fortran and C++ files based on the templates
    #-------------------------------------------------------------------------
    templates = [(network_template, network_file, "Fortran"),
                 (header_template, header_file, "C++")]

    for tmp, out_file, lang in templates:

        print("writing {}".format(out_file))

        # read the template
        try:
            template = open(tmp, "r")
        except IOError:
            sys.exit("write_network.py: ERROR: file {} does not exist".format(tmp))
        else:
            template_lines = template.readlines()
            template.close()

        # output the new file, inserting the species info in between the @@...@@
        fout = open(out_file, "w")

        for line in template_lines:

            index = line.find("@@")

            if index >= 0:
                index2 = line.rfind("@@")

                keyword = line[index+len("@@"):index2]
                indent = index*" "

                if keyword == "NSPEC":
                    fout.write(line.replace("@@NSPEC@@", str(len(species))))

                elif keyword == "NAUX":
                    fout.write(line.replace("@@NAUX@@", str(len(aux_vars))))

                elif keyword == "SPEC_NAMES":
                    if lang == "Fortran":
                        for n, spec in enumerate(species):
                            fout.write("{}spec_names({}) = \"{}\"\n".format(indent, n+1, spec.name))

                    elif lang == "C++":
                        for n, spec in enumerate(species):
                            fout.write("{}\"{}\",   // {} \n".format(indent, spec.name, n))

                elif keyword == "SHORT_SPEC_NAMES":
                    if lang == "Fortran":
                        for n, spec in enumerate(species):
                            fout.write("{}short_spec_names({}) = \"{}\"\n".format(indent, n+1, spec.short_name))

                    elif lang == "C++":
                        for n, spec in enumerate(species):
                            fout.write("{}\"{}\",   // {} \n".format(indent, spec.short_name, n))

                elif keyword == "AION":
                    if lang == "Fortran":
                        for n, spec in enumerate(species):
                            fout.write("{}aion({}) = {}_rt\n".format(indent, n+1, spec.A))

                    elif lang == "C++":
                        for n, spec in enumerate(species):
                            fout.write("{}{},   // {} \n".format(indent, spec.A, n))

                elif keyword == "AION_INV":
                    if lang == "Fortran":
                        for n, spec in enumerate(species):
                            fout.write("{}aion_inv({}) = 1.0_rt/{}_rt\n".format(indent, n+1, spec.A))

                    elif lang == "C++":
                        for n, spec in enumerate(species):
                            fout.write("{}1.0/{},   // {} \n".format(indent, spec.A, n))

                elif keyword == "ZION":
                    if lang == "Fortran":
                        for n, spec in enumerate(species):
                            fout.write("{}zion({}) = {}_rt\n".format(indent, n+1, spec.Z))

                    elif lang == "C++":
                        for n, spec in enumerate(species):
                            fout.write("{}{},   // {}\n".format(indent, spec.Z, n))

                elif keyword == "AUX_NAMES":
                    if lang == "Fortran":
                        for n, aux in enumerate(aux_vars):
                            fout.write("{}aux_names({}) = \"{}\"\n".format(indent, n+1, aux.name))

                    elif lang == "C++":
                        for n, aux in enumerate(aux_vars):
                            fout.write("{}\"{}\",   // {} \n".format(indent, aux.name, n))

                elif keyword == "SHORT_AUX_NAMES":
                    if lang == "Fortran":
                        for n, aux in enumerate(aux_vars):
                            fout.write("{}short_aux_names({}) = \"{}\"\n".format(indent, n+1, aux.name))

                    elif lang == "C++":
                        for n, aux in enumerate(aux_vars):
                            fout.write("{}\"{}\",   // {} \n".format(indent, aux.name, n))

                elif keyword == "PROPERTIES":
                    if lang == "C++":
                        for p in properties:
                            print(p)
                            fout.write("{}constexpr int {} = {};\n".format(indent, p, properties[p]))

                elif keyword == "SPECIES_ENUM":
                    if lang == "C++":
                        for n, spec in enumerate(species):
                            if n == 0:
                                fout.write("{}{}=1,\n".format(indent, spec.short_name.capitalize()))
                            else:
                                fout.write("{}{},\n".format(indent, spec.short_name.capitalize()))
                        fout.write("{}NumberSpecies={}\n".format(indent, species[-1].short_name.capitalize()))

                elif keyword == "AUXZERO_ENUM":
                    if lang == "C++":
                        if aux_vars:
                            for n, aux in enumerate(aux_vars):
                                if n == 0:
                                    fout.write("{}i{}=0,\n".format(indent, aux.name.lower()))
                                else:
                                    fout.write("{}i{},\n".format(indent, aux.name.lower()))
                            fout.write("{}NumberAux=i{}\n".format(indent, aux_vars[-1].name.lower()))

            else:
                fout.write(line)

        print(" ")
        fout.close()


def main():

    parser = argparse.ArgumentParser()
    parser.add_argument("-t", type=str, default="",
                        help="fortran template for the network")
    parser.add_argument("-o", type=str, default="",
                        help="fortran module output file name")
    parser.add_argument("--header_template", type=str, default="",
                        help="C++ header template file name")
    parser.add_argument("--header_output", type=str, default="",
                        help="C++ header output file name")
    parser.add_argument("-s", type=str, default="",
                        help="network file name")
    parser.add_argument("--other_properties", type=str, default="",
                        help="a NETWORK_PROPERTIES file with other network properties")
    parser.add_argument("--defines", type=str, default="",
                        help="and preprocessor defines that are used in building the code")

    args = parser.parse_args()

    if args.t == "" or args.o == "":
        sys.exit("write_probin.py: ERROR: invalid calling sequence")

    write_network(args.t, args.header_template,
                  args.s, args.other_properties,
                  args.o, args.header_output, args.defines)

if __name__ == "__main__":
    main()
