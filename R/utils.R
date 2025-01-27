#' Print information about fafbseg setup including tokens and python modules
#'
#' @description Print information about your \bold{fafbseg} setup including your
#'   FlyWire/ChunkedGraph authentication tokens, Python modules and the
#'   nat.h5reg / java setup required for transforming points between EM and
#'   light level template brains.
#'
#' @param pymodules Additional python modules to check beyond the standard ones
#'   that \bold{fafbseg} knows about such as \code{cloudvolume}. When set to
#'   \code{FALSE}, this turns off the Python module report altogether.
#'
#' @export
#' @examples
#' \donttest{
#' dr_fafbseg(pymodules=FALSE)
#' }
dr_fafbseg <- function(pymodules=NULL) {
  flywire_report()
  cat("\n")
  google_report()
  cat("\n")
  res=py_report(pymodules = pymodules)
  cat("\n")
  if(requireNamespace("nat.h5reg", quietly = T) &&
     utils::packageVersion("nat.h5reg")>="0.4.1")
    nat.h5reg::dr_h5reg()
  invisible(res)
}

google_report <- function() {
  message("Google FFN1 segmentation\n----")
  zipdir=getOption("fafbseg.skelziproot")
  if(isTRUE(nzchar(zipdir))) {
    cat("FFN1 skeletons located at:\n", zipdir, "\n")
  } else {
    ui_todo(paste('Set the `fafbseg.skelziproot` option:\n',
                  "{ui_code('options(fafbseg.skelziproot=\"/path/to/zips\")')}",
                  "\nif you want to use FFN1 skeleton files!"))
  }
}

#' @importFrom usethis ui_todo ui_code
flywire_report <- function() {
  message("FlyWire\n----")
  chunkedgraph_credentials_path = file.path(cv_secretdir(),"chunkedgraph-secret.json")
  if(file.exists(chunkedgraph_credentials_path)) {
    cat("FlyWire/CloudVolume credentials available at:\n", chunkedgraph_credentials_path,"\n")
  }

  token=try(chunkedgraph_token(cached = F), silent = TRUE)

  if(inherits(token, "try-error")) {
    ui_todo(paste('No valid FlyWire token found. Set your token by doing:\n',
                  "{ui_code('flywire_set_token()')}"))
  } else{
    cat("Valid FlyWire ChunkedGraph token is set!\n")
  }

  u=check_cloudvolume_url(set = F)
  cat("\nFlywire cloudvolume URL:", u)
}

check_reticulate <- function() {
  if(!requireNamespace('reticulate', quietly = TRUE)) {
    ui_todo(paste('Install reticulate (python interface) package with:\n',
                  "{ui_code('install.packages(\"reticulate\")')}"))
    cat("reticulate: not installed\n", )
    return(invisible(FALSE))
  }
  invisible(TRUE)
}

#' @importFrom usethis ui_todo ui_code
py_report <- function(pymodules=NULL) {
  message("Python\n----")
  check_reticulate()
  print(reticulate::py_discover_config())
  if(isFALSE(pymodules))
    return(invisible(NULL))
  cat("\n")

  pkgs=c("cloudvolume", "DracoPy", "meshparty", "skeletor", "pykdtree",
         "pyembree", "annotationframeworkclient", "pychunkedgraph", "igneous",
         pymodules)

  pyinfo=py_module_info(pkgs)
  print(pyinfo)
  invisible(pyinfo)
}

py_module_info <- function(modules) {
  if(!requireNamespace('reticulate', quietly = TRUE)) {
    return(NULL)
  }
  modules=unique(modules)
  paths=character(length(modules))
  names(paths)=modules
  versions=character(length(modules))
  names(versions)=modules
  available=logical(length(modules))
  names(available)=modules

  for (m in modules) {
    mod=tryCatch(reticulate::import(m), error=function(e) NULL)
    available[m]=!is.null(mod)
    if(!available[m])
      next
    paths[m]=tryCatch(mod$`__path__`, error=function(e) "")
    versions[m]=tryCatch(mod$`__version__`, error=function(e) "")
  }
  df=data.frame(module=modules,
                available=available,
                version=versions,
                path=paths,
                stringsAsFactors = F)
  row.names(df)=NULL
  df
}

# parse an array of python 64 bit integer ids to bit64::integer64 or character
pyids2bit64 <- function(x, as_character=TRUE) {
  np=py_np()
  if(inherits(x, 'python.builtin.list') || inherits(x, 'python.builtin.int') ) {
    x=np$asarray(x, dtype='i8')
  }

  if(isFALSE(as.character(x$dtype)=='int64')) {
    if(isFALSE(as.character(x$dtype)=='uint64'))
      stop("I only accept dtype=int64 or uint64 numpy arrays!")
    # we have uint64 input, check that itcan be represented as int64
    max=np$amax(x)
    # convert to string (in python)
    strmax=reticulate::py_str(max)
    maxint64="9223372036854775807"
    # the hallmark of overflow is that character vectors > maxint64 -> maxint64
    if(strmax!=maxint64 && as.integer64(strmax)==maxint64)
      stop("int64 overflow! uint64 id cannot be represented as int64")
  }

  tf=tempfile()
  on.exit(unlink(tf))
  x$tofile(tf)
  fi=file.info(tf)
  if(fi$size%%8L != 0) {
    stop("Trouble parsing python int64. Binary data not a multiple of 8 bytes")
  }
  # read in as double but then set class manually

  ids=readBin(tf, what = 'double', n=fi$size/8, size = 8)
  class(ids)="integer64"
  if(as_character) ids=as.character(ids)
  ids
}

py_np <- memoise::memoise(function(convert = FALSE) {
  np=reticulate::import('numpy', as='np', convert = convert)
  np
})

# convert R ids (which may be integer64/character/int/numeric) to
# a list of python ints or a numpy array via integer64
rids2pyint <- function(x, numpyarray=F, usefile=NA) {
  check_package_available('reticulate')
  np=py_np(convert=FALSE)
  npa <- if(!isTRUE(usefile) && (length(x)<1e4 || isFALSE(usefile))) {
    ids=as.character(x)
    str=if(length(ids)==1) ids else paste0(ids, collapse=",")
    np$fromstring(str, dtype='i8', sep = ",")
  } else {
    x=as.integer64(x)
    tf <- tempfile(fileext = '.bin')
    on.exit(unlink(tf))
    writeBin(unclass(x), tf, size = 8L)
    np$fromfile(tf, dtype = "i8")
  }
  if(isTRUE(numpyarray)) npa else npa$tolist()
}

# convert 64 bit integer ids to raw bytes
# assume that this should be little endian for flywire servers
# set to current platform when null
rids2raw <-function(ids, endian="little", ...) {
  if(is.null(endian)) endian=.Platform$endian
  ids=as.integer64(ids)
  rc=rawConnection(raw(0), "wb")
  on.exit(close(rc))
  writeBin(unclass(ids), rc, size = 8L, endian=endian, ...)
  rawConnectionValue(rc)
}

check_package_available <- function(pkg) {
  if(!requireNamespace(pkg, quietly = TRUE)) {
    stop("Please install suggested package: ", pkg)
  }
}

# hidden, also in hemibrainr
add_field_seq <- function(x, entries, field = "bodyid"){
  x = nat::as.neuronlist(x)
  if(length(entries)!=length(x)){
    stop("The length of the entries to add must be the same as the length of the neuronlist, x")
  }
  nl = nat::neuronlist()
  for(i in 1:length(x)){
    y = x[[i]]
    entry = entries[i]
    y[[field]] = entry
    y = nat::as.neuronlist(y)
    names(y) = entry
    nl = nat::union(nl, y)
  }
  nl[,] = x[,]
  nl
}

# hidden
nullToZero <- function(x, fill = 0) {
  if(is.list(x)){
    x[sapply(x, is.null)] <- fill
  }else{
    x = sapply(x, function(y) ifelse(is.null(y)||!length(y), fill, y))
    if(!length(x)){
      x = fill
    }
  }
  x
}

#' Simple Python installation for use with R/fafbseg/FlyWire
#'
#' @description Installs Python via an isolated miniconda environment as well as
#'   recommended packages for fafbseg. If you absolutely do not want to use
#'   miniconda (it is much simpler to get started) please read the Details
#'   section.
#'
#' @details The recommended Python install procedure installs a miniconda Python
#'   distribution. This will not be added to your system \code{PATH} by default
#'   and can be used exclusively by R. If you do not want to use miniconda, then
#'   you should at least a) make a Python virtual environment using virtualenv
#'   (or conda if you are managing your own conda install) and b) specify which
#'   Python you want to use with the \code{RETICULATE_PYTHON} environment
#'   variable. You can set \code{RETICULATE_PYTHON} with
#'   \code{usethis::edit_r_environ()}. If this sounds complicated, we suggest
#'   sticking to the default \code{miniconda=TRUE} approach.
#'
#'   Note that that after installing miniconda Python for the first time or
#'   updating your miniconda install, you will likely be asked to restart R.
#'   This is because you cannot restart the Python interpreter linked to an R
#'   session. Therefore if Python was already running in this session, you must
#'   restart R to use your new Python install.
#'
#' @param pyinstall Whether to do a \code{"basic"} install (enough for most
#'   functionality) or a \code{"full"} install, which includes tools for
#'   skeletonising meshes. \code{"cleanenv"} will show you how to clean up your
#'   Python enviroment removing all packages. \code{"blast"} will show you how
#'   to completely remove your dedicated miniconda installation. Choosing
#'   what="none" skips update/install of Python and recommended packages only
#'   installing extras defined by \code{pkgs}.
#' @param miniconda Whether to use the reticulate package's default approach of
#'   a dedicated python for R based on miniconda (recommended, the default) or
#'   to allow the specification of a different system installed Python via the
#'   \code{RETICULATE_PYTHON} environment variable.
#' @param pkgs Additional python packages to install.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # just the basics
#' simple_python("basic")
#' # if you want to skeletonise meshes
#' simple_python("full")
#'
#' # To install a special package using the recommended approach
#' simple_python(pkgs="PyChunkedGraph")
#' # the same but without touching Python itself or the recommended packages
#' simple_python('none', pkgs='PyChunkedGraph')
#'
#' # install a specific version of cloud-volume package
#' simple_python('none', pkgs='cloud-volume~=3.8.0')
#'
#' # install all recommended packages but use your existing Python
#' # only do this if you know what you are doing ...
#' simple_python("full", miniconda=FALSE)
#' }
simple_python <- function(pyinstall=c("basic", "full", "cleanenv", "blast", "none"), pkgs=NULL, miniconda=TRUE) {

  check_reticulate()
  ourpip <- function(...)
    reticulate::py_install(..., pip = T, pip_options='--upgrade --prefer-binary')

  pyinstall=match.arg(pyinstall)
  if(pyinstall!="none")
    pyinstalled=simple_python_base(pyinstall, miniconda)
  if(pyinstall %in% c("cleanenv", "blast")) return(invisible(NULL))

  if(pyinstall %in% c("basic", "full")) {
    message("Installing cloudvolume")
    ourpip('cloud-volume')
  }
  if(pyinstall=="full") {
    message("Installing meshparty (includes Seung lab mesh skeletonisation)")
    ourpip('skeletor')
    message("Installing skeletor (Philipp Schlegel mesh skeletonisation)")
    ourpip('skeletor')
    message("Installing skeletor addons (for faster skeletonisation)")
    ourpip(c('fastremap', 'ncollpyde'))
    message("Installing pyembree package (so meshparty can give skeletons radius estimates)")
    # not sure this wlll always work, but definitely optional
    tryCatch(reticulate::conda_install(packages = 'pyembree'),
             error=function(e) warning(e))
  }
  if(!is.null(pkgs)) {
    message("Installing user-specified packages")
    ourpip(pkgs)
  }
}

# private python/conda related utility functions
#####

simple_python_base <- function(what, miniconda) {
  if(what=="cleanenv") {
    checkownpython(miniconda)
    e <- default_pyenv()
    message(
      "If you really want to clean the packages in your existing miniconda for R virtual env at:\n  ",
      e,
      "\ndo:\n",
      sprintf("  reticulate::conda_remove('%s')", e)
    )
    return(invisible(NULL))
  } else if(what=='blast') {
    checkownpython(miniconda)
    message(
      "If you really want to blast your whole existing miniconda for R install at:\n  ",
      reticulate::miniconda_path(),
      "\ndo:\n",
      "  unlink(reticulate::miniconda_path(), recursive = TRUE)\n\n",
      "**Don't do this without verifying that the path above correctly identifies your installation!**"
    )
    return(invisible(NULL))
  }

  py_was_running <- reticulate::py_available()
  original_python <- current_python()

  pychanged=FALSE
  if(miniconda) {
    if(nzchar(Sys.getenv("RETICULATE_PYTHON")))
      stop(call. = F, "You have chosen a specific Python via the RETICULATE_PYTHON environment variable.\n",
           "simple_python does not recommend this and suggests that you unset this environment variable, e.g. by doing:\n",
           "usethis::edit_r_environ()",
           "However if you are sure you want to use another Python then do:\n",
           "simple_python(miniconda=FALSE)")

    message("Installing/updating a dedicated miniconda python environment for R")
    tryCatch({
      reticulate::install_miniconda()
      pychanged = TRUE
    },
    error = function(e) {
      if (grepl("already installed", as.character(e)))
        pychanged = update_miniconda_base()
    })
    if(py_was_running && pychanged) {
      stop(call. = F, "You have just updated your version of Python on disk.\n",
           "  But there was already a different Python version attached to this R session.\n",
           "  **Restart R** and run `simple_python` again to use your new Python!")
    }

  } else {
    message("Using the following existing python install. I hope you know what you're doing!")
    print(reticulate::py_config())
    if (!nzchar(Sys.getenv("RETICULATE_PYTHON"))) {
      warning(call. = F,
        "When using a non-standard Python setup, we recommend that you tell R\n",
        "  exactly which non-standard Python install to use\n",
        "  by setting the RETICULATE_PYTHON environment variable. You can do this with:\n",
        "usethis::edit_r_environ()\n",
        "  and adding a line to your .Renviron file like:\n",
        'RETICULATE_PYTHON="/opt/miniconda3/envs/r-reticulate/bin/python"'
      )
    }
  }
  pychanged
}

checkownpython <- function(dedicatedpython) {
  if(nzchar(Sys.getenv("RETICULATE_PYTHON")) || !dedicatedpython)
    stop("You have specified a non-standard Python. Sorry you're on your own!")
}

current_python <- function() {
  conf=reticulate::py_discover_config()
  structure(file.mtime(conf$python), .Names=conf$python)
}

default_pyenv <- function() {
  conf=reticulate::py_discover_config()
  conf$pythonhome
  env=sub(":.*", "", conf$pythonhome)
  env
}

# my own update function so I that can check if it actually updated anything
update_miniconda_base <- function() {
  path=reticulate::miniconda_path()
  exe <- if (identical(.Platform$OS.type, "windows"))
    "condabin/conda.bat"
  else "bin/conda"
  conda=file.path(path, exe)

  res=system2(conda, c("update", "--yes", "--json","--name", "base", "conda"), stdout = T)
  if(!jsonlite::validate(res))
    stop("Unable to parse results of conda update")

  js=jsonlite::fromJSON(res)
  # true when updated
  return(length(js$actions)>0)
}
