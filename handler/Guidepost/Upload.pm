#
#   mod_perl handler, upload, part of openstreetmap.cz
#   Copyright (C) 2015, 2016 Michal Grezl
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software Foundation,
#   Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
#

package Guidepost::Upload;

use utf8;
use JSON;

use Apache2::Connection ();
use Apache2::Const -compile => qw(OK SERVER_ERROR NOT_FOUND);
use Apache2::Filter ();
use Apache2::Reload;
use Apache2::Request;
use Apache2::RequestIO ();
use Apache2::RequestRec ();
use Apache2::URI ();
use Apache2::Upload;

use APR::Brigade ();
use APR::Bucket ();
use APR::Const -compile;
use APR::URI ();
use constant IOBUFSIZE => 8192;
use APR::Request;

use DBI;

use Data::Dumper;
use Scalar::Util qw(looks_like_number);

use Geo::JSON;
use Geo::JSON::Point;
use Geo::JSON::Feature;
use Geo::JSON::FeatureCollection;

use Sys::Syslog;
use HTML::Entities;

use File::Copy;
use Encode;

use Image::ExifTool;
use LWP::Simple;

use Geo::Inverse;
use Geo::Distance;

use jQuery::File::Upload;
use Inline::Files;

my $dbh;
my $BBOX = 0;
my $LIMIT = 0;
my $minlon;
my $minlat;
my $maxlon;
my $maxlat;
my $error_result;
my $remote_ip;
my $dbpath;

################################################################################
sub handler
################################################################################
{
  $BBOX = 0;
  $LIMIT = 0;

  $r = Apache2::Request->new(shift,
                             POST_MAX => 10 * 1024 * 1024, # in bytes, so 10M
                             DISABLE_UPLOADS => 0,
                             TEMP_DIR => "/tmp"
                            );
  $r->no_cache(1);

  $dbpath = $r->dir_config("dbpath");

  openlog('upload', 'pid', 'user');

  my $uri = $r->uri;      # what does the URI (URL) look like ?
  $r->no_cache(1);

  $r->content_type('text/html; charset=utf-8');

  syslog("info", "uri:".$r->uri);

  if ($uri =~ "phase1") {
    $r->print(&phase1());
  }

  if ($uri =~ "form") {
    &generate_html();
  }

  if ($uri =~ "info") {
    &i();
  }

  if ($uri =~ "phase2") {
  }

  closelog();

  return Apache2::Const::OK;
}

sub form
{
  $r->print(<<EOF);
  <html><body>
  <form enctype="multipart/form-data" name="files" action="/test/y" method="POST">
    File 1 <input type="file" name="file1"><br>
    File 2 <input type="file" name="file2"><br><br>
    <input type="submit" name="submit" value="Upload these files">
  </form>
 </body></html>
EOF
}

################################################################################
sub phase1
################################################################################
{
  my $req1 = Apache2::Request->new($r) or die;
  my $d = Dumper(\$req1);

  @uploads = $r->upload();

  my @a = (status => "success");
  my %file;

  foreach $file (@uploads) {
    $error = "";
    $upload = $r->upload($file);

# file content
#    my $io = $upload->io;

    $file{name} = $upload->filename();
    $file{size} = $upload->size();

    $final = "/var/www/api/uploads/" . $upload->filename();

    $error = "file exist" unless -f $final;

    if (!$upload->link($final)) {
     $error = "cannot link";
    }

    my ($lat, $lon, $time) = &exif($final);

    $file{"lat"} = $lat;
    $file{"lon"} = $lon;
    $file{"time"} = $time;

    if ($error ne "" ) {
      $file{"error"} = $error;
    }

    push @a, \%file;

  }

  $files{files}= \@a;
  $out = encode_json(\%files);
  return $out;
}

################################################################################
sub exif
################################################################################
{
  my $image_location = "/home/walley/www/mapy/img/guidepost";
  my ($image) = @_;

  syslog("info", "exif: " . $image);
  my $exifTool = new Image::ExifTool;
  $exifTool->Options(Unknown => 1);
  my $info = $exifTool->ImageInfo($image );
  my $group = '';
  my $tag;
  foreach $tag ($exifTool->GetFoundTags('Group0')) {
    if ($group ne $exifTool->GetGroup($tag)) {
      $group = $exifTool->GetGroup($tag);
    }
    my $val = $info->{$tag};
    if (ref $val eq 'SCALAR') {
      if ($$val =~ /^Binary data/) {
        $val = "($$val)";
      } else {
        my $len = length($$val);
        $val = "(Binary data $len bytes)";
      }
    }
    $exif{$group}{$exifTool->GetDescription($tag)} = $val;
  }


  if (defined $exif{Composite}{"GPS Date/Time"}) {
    $gps_time = $exif{Composite}{"GPS Date/Time"};
  } else {
    $gps_time = "";
  }

  if (defined $exif{"Composite"}{"GPS Latitude"})  {
    syslog("info", "yes");
    $gps_lat = $exif{"Composite"}{"GPS Latitude"};
  } else {
    syslog("info", "no");
    $gps_lat = "cc";
  }

  if (defined $exif{Composite}{"GPS Longitude"})  {
    $gps_lon = $exif{Composite}{"GPS Longitude"};
  } else {
    $gps_lon = "";
  }

  return ($gps_lat, $gps_lon, $gps_time);
}

################################################################################
sub phase2()
################################################################################
{
#move coords
#move photo to final location
#create db entry

}

################################################################################
sub generate_html
################################################################################
{
  my $out = "";

  $out .= "<!DOCTYPE html>\n";
  $out .= "<html>\n";
  $out .= "  <head>\n";
  $out .= "    <meta charset='utf-8'/>\n";
  $out .= "    <title>openstreetmap.cz upload form</title>\n";
  $out .= "    <style>\n";

  while (<STYLE>) {
        $out .= $_;
  }

  $out .= "    </style>\n";
  $out .= "  </head>\n";

  while (<BODY>) {
     $out .= $_;
  }

  $out .= "</html>\n";

  $r->print($out);

}

1;

################################################################################
################################################################################
################################################################################
################################################################################

__STYLE__
*{
    margin:0;
    padding:0;
}

html{
    min-height:900px;
}

a, a:visited {
    outline:none;
    color:#389dc1;
}

a:hover{
    text-decoration:none;
}

#upload{
    padding:5px;
    border-radius:3px;
    box-shadow: 0 0 10px rgba(0, 0, 0, 0.3);
 overflow:hidden;
}

#drop{
    padding: 40px 50px;
    margin-bottom: 30px;
    border: 20px solid rgba(0, 0, 0, 0);
    border-radius: 3px;
    text-align: center;
    text-transform: uppercase;

}

#drop a{
    background-color:#007a96;
    padding:12px 26px;
    color:#fff;
    font-size:14px;
    border-radius:2px;
    cursor:pointer;
    display:inline-block;
    margin-top:12px;
    line-height:1;
}

#drop a:hover{
    background-color:#0986a3;
}

#drop input{
   display:none;
}

#upload ul li{
white-space:nowrap;
    border-top:1px solid black;
    border-bottom:1px solid black;
}

#upload ul li input{
    display: none;
}

#upload ul li canvas{
    top: 15px;
    left: 32px;
}

#upload ul li span{
    width: 15px;
    height: 12px;
    top: 34px;
    right: 33px;
    cursor:pointer;
}

#upload ul li.working span{
    height: 16px;
}

#upload ul li.error p{
    color:red;
}

.container::after {
    content:"";
    display:table;
    clear:both;
}

__BODY__
  <body>
    <form id="upload" method="post" action="http://api.openstreetmap.cz/upload/phase1/" enctype="multipart/form-data">
      <input type="text" name="author" value="autor">
      <div id="drop">
        Drop Here
        <a>Browse</a>
        <input type="file" name="upl" multiple />
      </div>

      <ul>
        <!-- The file uploads will be shown here -->
      </ul>

    </form>
  </body>

__JQUERYFILEUPLOADJS__
/*
 * jQuery File Upload Plugin
 * https://github.com/blueimp/jQuery-File-Upload
 *
 * Copyright 2010, Sebastian Tschan
 * https://blueimp.net
 *
 * Licensed under the MIT license:
 * http://www.opensource.org/licenses/MIT
 */

/* jshint nomen:false */
/* global define, require, window, document, location, Blob, FormData */

(function (factory) {
  'use strict';
  if (typeof define === 'function' && define.amd) {
    define([
      'jquery',
      'jquery.ui.widget'
    ], factory);
  } else if (typeof exports === 'object') {
    factory(
      require('jquery'),
      require('./vendor/jquery.ui.widget')
    );
  } else {
    factory(window.jQuery);
  }
}(function ($) {
  'use strict';

  $.support.fileInput = !(new RegExp(
    '(Android (1\\.[0156]|2\\.[01]))' +
      '|(Windows Phone (OS 7|8\\.0))|(XBLWP)|(ZuneWP)|(WPDesktop)' +
      '|(w(eb)?OSBrowser)|(webOS)' +
      '|(Kindle/(1\\.0|2\\.[05]|3\\.0))'
  ).test(window.navigator.userAgent) ||
    $('<input type="file">').prop('disabled'));

  $.support.xhrFileUpload = !!(window.ProgressEvent && window.FileReader);
  $.support.xhrFormDataFileUpload = !!window.FormData;

  $.support.blobSlice = window.Blob && (Blob.prototype.slice ||
    Blob.prototype.webkitSlice || Blob.prototype.mozSlice);

  function getDragHandler(type) {
    var isDragOver = type === 'dragover';
    return function (e) {
      e.dataTransfer = e.originalEvent && e.originalEvent.dataTransfer;
      var dataTransfer = e.dataTransfer;
      if (dataTransfer && $.inArray('Files', dataTransfer.types) !== -1 &&
          this._trigger(
            type,
            $.Event(type, {delegatedEvent: e})
          ) !== false) {
        e.preventDefault();
        if (isDragOver) {
          dataTransfer.dropEffect = 'copy';
        }
      }
    };
  }

  $.widget('blueimp.fileupload', {

    options: {
      dropZone: $(document),
      pasteZone: undefined,
      fileInput: undefined,
      replaceFileInput: true,
      paramName: undefined,
      singleFileUploads: true,
      limitMultiFileUploads: undefined,
      limitMultiFileUploadSize: undefined,
      limitMultiFileUploadSizeOverhead: 512,
      sequentialUploads: false,
      limitConcurrentUploads: undefined,
      forceIframeTransport: false,
      redirect: undefined,
      redirectParamName: undefined,
      postMessage: undefined,
      multipart: true,
      maxChunkSize: undefined,
      uploadedBytes: undefined,
      recalculateProgress: true,
      progressInterval: 100,
      bitrateInterval: 500,
      autoUpload: true,

      messages: {
        uploadedBytes: 'Uploaded bytes exceed file size'
      },

      i18n: function (message, context) {
        message = this.messages[message] || message.toString();
        if (context) {
          $.each(context, function (key, value) {
            message = message.replace('{' + key + '}', value);
          });
        }
        return message;
      },

      formData: function (form) {
        return form.serializeArray();
      },

      add: function (e, data) {
        if (e.isDefaultPrevented()) {
          return false;
        }
        if (data.autoUpload || (data.autoUpload !== false &&
            $(this).fileupload('option', 'autoUpload'))) {
          data.process().done(function () {
            data.submit();
          });
        }
      },

      processData: false,
      contentType: false,
      cache: false,
      timeout: 0
    },

    _specialOptions: [
      'fileInput',
      'dropZone',
      'pasteZone',
      'multipart',
      'forceIframeTransport'
    ],

    _blobSlice: $.support.blobSlice && function () {
      var slice = this.slice || this.webkitSlice || this.mozSlice;
      return slice.apply(this, arguments);
    },

    _BitrateTimer: function () {
      this.timestamp = ((Date.now) ? Date.now() : (new Date()).getTime());
      this.loaded = 0;
      this.bitrate = 0;
      this.getBitrate = function (now, loaded, interval) {
        var timeDiff = now - this.timestamp;
        if (!this.bitrate || !interval || timeDiff > interval) {
          this.bitrate = (loaded - this.loaded) * (1000 / timeDiff) * 8;
          this.loaded = loaded;
          this.timestamp = now;
        }
        return this.bitrate;
      };
    },

    _isXHRUpload: function (options) {
      return !options.forceIframeTransport &&
        ((!options.multipart && $.support.xhrFileUpload) ||
        $.support.xhrFormDataFileUpload);
    },

    _getFormData: function (options) {
      var formData;
      if ($.type(options.formData) === 'function') {
        return options.formData(options.form);
      }
      if ($.isArray(options.formData)) {
        return options.formData;
      }
      if ($.type(options.formData) === 'object') {
        formData = [];
        $.each(options.formData, function (name, value) {
          formData.push({name: name, value: value});
        });
        return formData;
      }
      return [];
    },

    _getTotal: function (files) {
      var total = 0;
      $.each(files, function (index, file) {
        total += file.size || 1;
      });
      return total;
    },

    _initProgressObject: function (obj) {
      var progress = {
        loaded: 0,
        total: 0,
        bitrate: 0
      };
      if (obj._progress) {
        $.extend(obj._progress, progress);
      } else {
        obj._progress = progress;
      }
    },

    _initResponseObject: function (obj) {
      var prop;
      if (obj._response) {
        for (prop in obj._response) {
          if (obj._response.hasOwnProperty(prop)) {
            delete obj._response[prop];
          }
        }
      } else {
        obj._response = {};
      }
    },

    _onProgress: function (e, data) {
      if (e.lengthComputable) {
        var now = ((Date.now) ? Date.now() : (new Date()).getTime()),
          loaded;
        if (data._time && data.progressInterval &&
            (now - data._time < data.progressInterval) &&
            e.loaded !== e.total) {
          return;
        }
        data._time = now;
        loaded = Math.floor(
          e.loaded / e.total * (data.chunkSize || data._progress.total)
        ) + (data.uploadedBytes || 0);
        this._progress.loaded += (loaded - data._progress.loaded);
        this._progress.bitrate = this._bitrateTimer.getBitrate(
          now,
          this._progress.loaded,
          data.bitrateInterval
        );
        data._progress.loaded = data.loaded = loaded;
        data._progress.bitrate = data.bitrate = data._bitrateTimer.getBitrate(
          now,
          loaded,
          data.bitrateInterval
        );
        this._trigger(
          'progress',
          $.Event('progress', {delegatedEvent: e}),
          data
        );
        this._trigger(
          'progressall',
          $.Event('progressall', {delegatedEvent: e}),
          this._progress
        );
      }
    },

    _initProgressListener: function (options) {
      var that = this,
        xhr = options.xhr ? options.xhr() : $.ajaxSettings.xhr();
      if (xhr.upload) {
        $(xhr.upload).bind('progress', function (e) {
          var oe = e.originalEvent;
          e.lengthComputable = oe.lengthComputable;
          e.loaded = oe.loaded;
          e.total = oe.total;
          that._onProgress(e, options);
        });
        options.xhr = function () {
          return xhr;
        };
      }
    },

    _isInstanceOf: function (type, obj) {
      return Object.prototype.toString.call(obj) === '[object ' + type + ']';
    },

    _initXHRData: function (options) {
      var that = this,
        formData,
        file = options.files[0],
        multipart = options.multipart || !$.support.xhrFileUpload,
        paramName = $.type(options.paramName) === 'array' ?
          options.paramName[0] : options.paramName;
      options.headers = $.extend({}, options.headers);
      if (options.contentRange) {
        options.headers['Content-Range'] = options.contentRange;
      }
      if (!multipart || options.blob || !this._isInstanceOf('File', file)) {
        options.headers['Content-Disposition'] = 'attachment; filename="' +
          encodeURI(file.name) + '"';
      }
      if (!multipart) {
        options.contentType = file.type || 'application/octet-stream';
        options.data = options.blob || file;
      } else if ($.support.xhrFormDataFileUpload) {
        if (options.postMessage) {
          formData = this._getFormData(options);
          if (options.blob) {
            formData.push({
              name: paramName,
              value: options.blob
            });
          } else {
            $.each(options.files, function (index, file) {
              formData.push({
                name: ($.type(options.paramName) === 'array' &&
                  options.paramName[index]) || paramName,
                value: file
              });
            });
          }
        } else {
          if (that._isInstanceOf('FormData', options.formData)) {
            formData = options.formData;
          } else {
            formData = new FormData();
            $.each(this._getFormData(options), function (index, field) {
              formData.append(field.name, field.value);
            });
          }
          if (options.blob) {
            formData.append(paramName, options.blob, file.name);
          } else {
            $.each(options.files, function (index, file) {
              if (that._isInstanceOf('File', file) ||
                  that._isInstanceOf('Blob', file)) {
                formData.append(
                  ($.type(options.paramName) === 'array' &&
                    options.paramName[index]) || paramName,
                  file,
                  file.uploadName || file.name
                );
              }
            });
          }
        }
        options.data = formData;
      }
      options.blob = null;
    },

    _initIframeSettings: function (options) {
      var targetHost = $('<a></a>').prop('href', options.url).prop('host');
      options.dataType = 'iframe ' + (options.dataType || '');
      options.formData = this._getFormData(options);
      if (options.redirect && targetHost && targetHost !== location.host) {
        options.formData.push({
          name: options.redirectParamName || 'redirect',
          value: options.redirect
        });
      }
    },

    _initDataSettings: function (options) {
      if (this._isXHRUpload(options)) {
        if (!this._chunkedUpload(options, true)) {
          if (!options.data) {
            this._initXHRData(options);
          }
          this._initProgressListener(options);
        }
        if (options.postMessage) {
          options.dataType = 'postmessage ' + (options.dataType || '');
        }
      } else {
        this._initIframeSettings(options);
      }
    },

    _getParamName: function (options) {
      var fileInput = $(options.fileInput),
        paramName = options.paramName;
      if (!paramName) {
        paramName = [];
        fileInput.each(function () {
          var input = $(this),
            name = input.prop('name') || 'files[]',
            i = (input.prop('files') || [1]).length;
          while (i) {
            paramName.push(name);
            i -= 1;
          }
        });
        if (!paramName.length) {
          paramName = [fileInput.prop('name') || 'files[]'];
        }
      } else if (!$.isArray(paramName)) {
        paramName = [paramName];
      }
      return paramName;
    },

    _initFormSettings: function (options) {
      if (!options.form || !options.form.length) {
        options.form = $(options.fileInput.prop('form'));
        if (!options.form.length) {
          options.form = $(this.options.fileInput.prop('form'));
        }
      }
      options.paramName = this._getParamName(options);
      if (!options.url) {
        options.url = options.form.prop('action') || location.href;
      }
      options.type = (options.type ||
        ($.type(options.form.prop('method')) === 'string' &&
          options.form.prop('method')) || ''
        ).toUpperCase();
      if (options.type !== 'POST' && options.type !== 'PUT' &&
          options.type !== 'PATCH') {
        options.type = 'POST';
      }
      if (!options.formAcceptCharset) {
        options.formAcceptCharset = options.form.attr('accept-charset');
      }
    },

    _getAJAXSettings: function (data) {
      var options = $.extend({}, this.options, data);
      this._initFormSettings(options);
      this._initDataSettings(options);
      return options;
    },

    _getDeferredState: function (deferred) {
      if (deferred.state) {
        return deferred.state();
      }
      if (deferred.isResolved()) {
        return 'resolved';
      }
      if (deferred.isRejected()) {
        return 'rejected';
      }
      return 'pending';
    },

    _enhancePromise: function (promise) {
      promise.success = promise.done;
      promise.error = promise.fail;
      promise.complete = promise.always;
      return promise;
    },

    _getXHRPromise: function (resolveOrReject, context, args) {
      var dfd = $.Deferred(),
        promise = dfd.promise();
      context = context || this.options.context || promise;
      if (resolveOrReject === true) {
        dfd.resolveWith(context, args);
      } else if (resolveOrReject === false) {
        dfd.rejectWith(context, args);
      }
      promise.abort = dfd.promise;
      return this._enhancePromise(promise);
    },

    _addConvenienceMethods: function (e, data) {
      var that = this,
        getPromise = function (args) {
          return $.Deferred().resolveWith(that, args).promise();
        };
      data.process = function (resolveFunc, rejectFunc) {
        if (resolveFunc || rejectFunc) {
          data._processQueue = this._processQueue =
            (this._processQueue || getPromise([this])).then(
              function () {
                if (data.errorThrown) {
                  return $.Deferred()
                    .rejectWith(that, [data]).promise();
                }
                return getPromise(arguments);
              }
            ).then(resolveFunc, rejectFunc);
        }
        return this._processQueue || getPromise([this]);
      };
      data.submit = function () {
        if (this.state() !== 'pending') {
          data.jqXHR = this.jqXHR =
            (that._trigger(
              'submit',
              $.Event('submit', {delegatedEvent: e}),
              this
            ) !== false) && that._onSend(e, this);
        }
        return this.jqXHR || that._getXHRPromise();
      };
      data.abort = function () {
        if (this.jqXHR) {
          return this.jqXHR.abort();
        }
        this.errorThrown = 'abort';
        that._trigger('fail', null, this);
        return that._getXHRPromise(false);
      };
      data.state = function () {
        if (this.jqXHR) {
          return that._getDeferredState(this.jqXHR);
        }
        if (this._processQueue) {
          return that._getDeferredState(this._processQueue);
        }
      };
      data.processing = function () {
        return !this.jqXHR && this._processQueue && that
          ._getDeferredState(this._processQueue) === 'pending';
      };
      data.progress = function () {
        return this._progress;
      };
      data.response = function () {
        return this._response;
      };
    },

    _getUploadedBytes: function (jqXHR) {
      var range = jqXHR.getResponseHeader('Range'),
        parts = range && range.split('-'),
        upperBytesPos = parts && parts.length > 1 &&
          parseInt(parts[1], 10);
      return upperBytesPos && upperBytesPos + 1;
    },

    _chunkedUpload: function (options, testOnly) {
      options.uploadedBytes = options.uploadedBytes || 0;
      var that = this,
        file = options.files[0],
        fs = file.size,
        ub = options.uploadedBytes,
        mcs = options.maxChunkSize || fs,
        slice = this._blobSlice,
        dfd = $.Deferred(),
        promise = dfd.promise(),
        jqXHR,
        upload;
      if (!(this._isXHRUpload(options) && slice && (ub || mcs < fs)) ||
          options.data) {
        return false;
      }
      if (testOnly) {
        return true;
      }
      if (ub >= fs) {
        file.error = options.i18n('uploadedBytes');
        return this._getXHRPromise(
          false,
          options.context,
          [null, 'error', file.error]
        );
      }
      upload = function () {
        var o = $.extend({}, options),
          currentLoaded = o._progress.loaded;
        o.blob = slice.call(
          file,
          ub,
          ub + mcs,
          file.type
        );
        o.chunkSize = o.blob.size;
        o.contentRange = 'bytes ' + ub + '-' +
          (ub + o.chunkSize - 1) + '/' + fs;
        that._initXHRData(o);
        that._initProgressListener(o);
        jqXHR = ((that._trigger('chunksend', null, o) !== false && $.ajax(o)) ||
            that._getXHRPromise(false, o.context))
          .done(function (result, textStatus, jqXHR) {
            ub = that._getUploadedBytes(jqXHR) ||
              (ub + o.chunkSize);
            if (currentLoaded + o.chunkSize - o._progress.loaded) {
              that._onProgress($.Event('progress', {
                lengthComputable: true,
                loaded: ub - o.uploadedBytes,
                total: ub - o.uploadedBytes
              }), o);
            }
            options.uploadedBytes = o.uploadedBytes = ub;
            o.result = result;
            o.textStatus = textStatus;
            o.jqXHR = jqXHR;
            that._trigger('chunkdone', null, o);
            that._trigger('chunkalways', null, o);
            if (ub < fs) {
              upload();
            } else {
              dfd.resolveWith(
                o.context,
                [result, textStatus, jqXHR]
              );
            }
          })
          .fail(function (jqXHR, textStatus, errorThrown) {
            o.jqXHR = jqXHR;
            o.textStatus = textStatus;
            o.errorThrown = errorThrown;
            that._trigger('chunkfail', null, o);
            that._trigger('chunkalways', null, o);
            dfd.rejectWith(
              o.context,
              [jqXHR, textStatus, errorThrown]
            );
          });
      };
      this._enhancePromise(promise);
      promise.abort = function () {
        return jqXHR.abort();
      };
      upload();
      return promise;
    },

    _beforeSend: function (e, data) {
      if (this._active === 0) {
        this._trigger('start');
        this._bitrateTimer = new this._BitrateTimer();
        this._progress.loaded = this._progress.total = 0;
        this._progress.bitrate = 0;
      }
      this._initResponseObject(data);
      this._initProgressObject(data);
      data._progress.loaded = data.loaded = data.uploadedBytes || 0;
      data._progress.total = data.total = this._getTotal(data.files) || 1;
      data._progress.bitrate = data.bitrate = 0;
      this._active += 1;
      this._progress.loaded += data.loaded;
      this._progress.total += data.total;
    },

    _onDone: function (result, textStatus, jqXHR, options) {
      var total = options._progress.total,
        response = options._response;
      if (options._progress.loaded < total) {
        this._onProgress($.Event('progress', {
          lengthComputable: true,
          loaded: total,
          total: total
        }), options);
      }
      response.result = options.result = result;
      response.textStatus = options.textStatus = textStatus;
      response.jqXHR = options.jqXHR = jqXHR;
      this._trigger('done', null, options);
    },

    _onFail: function (jqXHR, textStatus, errorThrown, options) {
      var response = options._response;
      if (options.recalculateProgress) {
        this._progress.loaded -= options._progress.loaded;
        this._progress.total -= options._progress.total;
      }
      response.jqXHR = options.jqXHR = jqXHR;
      response.textStatus = options.textStatus = textStatus;
      response.errorThrown = options.errorThrown = errorThrown;
      this._trigger('fail', null, options);
    },

    _onAlways: function (jqXHRorResult, textStatus, jqXHRorError, options) {
      this._trigger('always', null, options);
    },

    _onSend: function (e, data) {
      if (!data.submit) {
        this._addConvenienceMethods(e, data);
      }
      var that = this,
        jqXHR,
        aborted,
        slot,
        pipe,
        options = that._getAJAXSettings(data),
        send = function () {
          that._sending += 1;
          options._bitrateTimer = new that._BitrateTimer();
          jqXHR = jqXHR || (
            ((aborted || that._trigger(
              'send',
              $.Event('send', {delegatedEvent: e}),
              options
            ) === false) &&
            that._getXHRPromise(false, options.context, aborted)) ||
            that._chunkedUpload(options) || $.ajax(options)
          ).done(function (result, textStatus, jqXHR) {
            that._onDone(result, textStatus, jqXHR, options);
          }).fail(function (jqXHR, textStatus, errorThrown) {
            that._onFail(jqXHR, textStatus, errorThrown, options);
          }).always(function (jqXHRorResult, textStatus, jqXHRorError) {
            that._onAlways(
              jqXHRorResult,
              textStatus,
              jqXHRorError,
              options
            );
            that._sending -= 1;
            that._active -= 1;
            if (options.limitConcurrentUploads &&
                options.limitConcurrentUploads > that._sending) {
              var nextSlot = that._slots.shift();
              while (nextSlot) {
                if (that._getDeferredState(nextSlot) === 'pending') {
                  nextSlot.resolve();
                  break;
                }
                nextSlot = that._slots.shift();
              }
            }
            if (that._active === 0) {
              that._trigger('stop');
            }
          });
          return jqXHR;
        };
      this._beforeSend(e, options);
      if (this.options.sequentialUploads ||
          (this.options.limitConcurrentUploads &&
          this.options.limitConcurrentUploads <= this._sending)) {
        if (this.options.limitConcurrentUploads > 1) {
          slot = $.Deferred();
          this._slots.push(slot);
          pipe = slot.then(send);
        } else {
          this._sequence = this._sequence.then(send, send);
          pipe = this._sequence;
        }
        pipe.abort = function () {
          aborted = [undefined, 'abort', 'abort'];
          if (!jqXHR) {
            if (slot) {
              slot.rejectWith(options.context, aborted);
            }
            return send();
          }
          return jqXHR.abort();
        };
        return this._enhancePromise(pipe);
      }
      return send();
    },

    _onAdd: function (e, data) {
      var that = this,
        result = true,
        options = $.extend({}, this.options, data),
        files = data.files,
        filesLength = files.length,
        limit = options.limitMultiFileUploads,
        limitSize = options.limitMultiFileUploadSize,
        overhead = options.limitMultiFileUploadSizeOverhead,
        batchSize = 0,
        paramName = this._getParamName(options),
        paramNameSet,
        paramNameSlice,
        fileSet,
        i,
        j = 0;
      if (!filesLength) {
        return false;
      }
      if (limitSize && files[0].size === undefined) {
        limitSize = undefined;
      }
      if (!(options.singleFileUploads || limit || limitSize) ||
          !this._isXHRUpload(options)) {
        fileSet = [files];
        paramNameSet = [paramName];
      } else if (!(options.singleFileUploads || limitSize) && limit) {
        fileSet = [];
        paramNameSet = [];
        for (i = 0; i < filesLength; i += limit) {
          fileSet.push(files.slice(i, i + limit));
          paramNameSlice = paramName.slice(i, i + limit);
          if (!paramNameSlice.length) {
            paramNameSlice = paramName;
          }
          paramNameSet.push(paramNameSlice);
        }
      } else if (!options.singleFileUploads && limitSize) {
        fileSet = [];
        paramNameSet = [];
        for (i = 0; i < filesLength; i = i + 1) {
          batchSize += files[i].size + overhead;
          if (i + 1 === filesLength ||
              ((batchSize + files[i + 1].size + overhead) > limitSize) ||
              (limit && i + 1 - j >= limit)) {
            fileSet.push(files.slice(j, i + 1));
            paramNameSlice = paramName.slice(j, i + 1);
            if (!paramNameSlice.length) {
              paramNameSlice = paramName;
            }
            paramNameSet.push(paramNameSlice);
            j = i + 1;
            batchSize = 0;
          }
        }
      } else {
        paramNameSet = paramName;
      }
      data.originalFiles = files;
      $.each(fileSet || files, function (index, element) {
        var newData = $.extend({}, data);
        newData.files = fileSet ? element : [element];
        newData.paramName = paramNameSet[index];
        that._initResponseObject(newData);
        that._initProgressObject(newData);
        that._addConvenienceMethods(e, newData);
        result = that._trigger(
          'add',
          $.Event('add', {delegatedEvent: e}),
          newData
        );
        return result;
      });
      return result;
    },

    _replaceFileInput: function (data) {
      var input = data.fileInput,
        inputClone = input.clone(true),
        restoreFocus = input.is(document.activeElement);
      data.fileInputClone = inputClone;
      $('<form></form>').append(inputClone)[0].reset();
      input.after(inputClone).detach();
      if (restoreFocus) {
        inputClone.focus();
      }
      $.cleanData(input.unbind('remove'));
      this.options.fileInput = this.options.fileInput.map(function (i, el) {
        if (el === input[0]) {
          return inputClone[0];
        }
        return el;
      });
      if (input[0] === this.element[0]) {
        this.element = inputClone;
      }
    },

    _handleFileTreeEntry: function (entry, path) {
      var that = this,
        dfd = $.Deferred(),
        errorHandler = function (e) {
          if (e && !e.entry) {
            e.entry = entry;
          }
          dfd.resolve([e]);
        },
        successHandler = function (entries) {
          that._handleFileTreeEntries(
            entries,
            path + entry.name + '/'
          ).done(function (files) {
            dfd.resolve(files);
          }).fail(errorHandler);
        },
        readEntries = function () {
          dirReader.readEntries(function (results) {
            if (!results.length) {
              successHandler(entries);
            } else {
              entries = entries.concat(results);
              readEntries();
            }
          }, errorHandler);
        },
        dirReader, entries = [];
      path = path || '';
      if (entry.isFile) {
        if (entry._file) {
          entry._file.relativePath = path;
          dfd.resolve(entry._file);
        } else {
          entry.file(function (file) {
            file.relativePath = path;
            dfd.resolve(file);
          }, errorHandler);
        }
      } else if (entry.isDirectory) {
        dirReader = entry.createReader();
        readEntries();
      } else {
        dfd.resolve([]);
      }
      return dfd.promise();
    },

    _handleFileTreeEntries: function (entries, path) {
      var that = this;
      return $.when.apply(
        $,
        $.map(entries, function (entry) {
          return that._handleFileTreeEntry(entry, path);
        })
      ).then(function () {
        return Array.prototype.concat.apply(
          [],
          arguments
        );
      });
    },

    _getDroppedFiles: function (dataTransfer) {
      dataTransfer = dataTransfer || {};
      var items = dataTransfer.items;
      if (items && items.length && (items[0].webkitGetAsEntry ||
          items[0].getAsEntry)) {
        return this._handleFileTreeEntries(
          $.map(items, function (item) {
            var entry;
            if (item.webkitGetAsEntry) {
              entry = item.webkitGetAsEntry();
              if (entry) {
                entry._file = item.getAsFile();
              }
              return entry;
            }
            return item.getAsEntry();
          })
        );
      }
      return $.Deferred().resolve(
        $.makeArray(dataTransfer.files)
      ).promise();
    },

    _getSingleFileInputFiles: function (fileInput) {
      fileInput = $(fileInput);
      var entries = fileInput.prop('webkitEntries') ||
          fileInput.prop('entries'),
        files,
        value;
      if (entries && entries.length) {
        return this._handleFileTreeEntries(entries);
      }
      files = $.makeArray(fileInput.prop('files'));
      if (!files.length) {
        value = fileInput.prop('value');
        if (!value) {
          return $.Deferred().resolve([]).promise();
        }
        files = [{name: value.replace(/^.*\\/, '')}];
      } else if (files[0].name === undefined && files[0].fileName) {
        $.each(files, function (index, file) {
          file.name = file.fileName;
          file.size = file.fileSize;
        });
      }
      return $.Deferred().resolve(files).promise();
    },

    _getFileInputFiles: function (fileInput) {
      if (!(fileInput instanceof $) || fileInput.length === 1) {
        return this._getSingleFileInputFiles(fileInput);
      }
      return $.when.apply(
        $,
        $.map(fileInput, this._getSingleFileInputFiles)
      ).then(function () {
        return Array.prototype.concat.apply(
          [],
          arguments
        );
      });
    },

    _onChange: function (e) {
      var that = this,
        data = {
          fileInput: $(e.target),
          form: $(e.target.form)
        };
      this._getFileInputFiles(data.fileInput).always(function (files) {
        data.files = files;
        if (that.options.replaceFileInput) {
          that._replaceFileInput(data);
        }
        if (that._trigger(
            'change',
            $.Event('change', {delegatedEvent: e}),
            data
          ) !== false) {
          that._onAdd(e, data);
        }
      });
    },

    _onPaste: function (e) {
      var items = e.originalEvent && e.originalEvent.clipboardData &&
          e.originalEvent.clipboardData.items,
        data = {files: []};
      if (items && items.length) {
        $.each(items, function (index, item) {
          var file = item.getAsFile && item.getAsFile();
          if (file) {
            data.files.push(file);
          }
        });
        if (this._trigger(
            'paste',
            $.Event('paste', {delegatedEvent: e}),
            data
          ) !== false) {
          this._onAdd(e, data);
        }
      }
    },

    _onDrop: function (e) {
      e.dataTransfer = e.originalEvent && e.originalEvent.dataTransfer;
      var that = this,
        dataTransfer = e.dataTransfer,
        data = {};
      if (dataTransfer && dataTransfer.files && dataTransfer.files.length) {
        e.preventDefault();
        this._getDroppedFiles(dataTransfer).always(function (files) {
          data.files = files;
          if (that._trigger(
              'drop',
              $.Event('drop', {delegatedEvent: e}),
              data
            ) !== false) {
            that._onAdd(e, data);
          }
        });
      }
    },

    _onDragOver: getDragHandler('dragover'),

    _onDragEnter: getDragHandler('dragenter'),

    _onDragLeave: getDragHandler('dragleave'),

    _initEventHandlers: function () {
      if (this._isXHRUpload(this.options)) {
        this._on(this.options.dropZone, {
          dragover: this._onDragOver,
          drop: this._onDrop,
          dragenter: this._onDragEnter,
          dragleave: this._onDragLeave
        });
        this._on(this.options.pasteZone, {
          paste: this._onPaste
        });
      }
      if ($.support.fileInput) {
        this._on(this.options.fileInput, {
          change: this._onChange
        });
      }
    },

    _destroyEventHandlers: function () {
      this._off(this.options.dropZone, 'dragenter dragleave dragover drop');
      this._off(this.options.pasteZone, 'paste');
      this._off(this.options.fileInput, 'change');
    },

    _setOption: function (key, value) {
      var reinit = $.inArray(key, this._specialOptions) !== -1;
      if (reinit) {
        this._destroyEventHandlers();
      }
      this._super(key, value);
      if (reinit) {
        this._initSpecialOptions();
        this._initEventHandlers();
      }
    },

    _initSpecialOptions: function () {
      var options = this.options;
      if (options.fileInput === undefined) {
        options.fileInput = this.element.is('input[type="file"]') ?
            this.element : this.element.find('input[type="file"]');
      } else if (!(options.fileInput instanceof $)) {
        options.fileInput = $(options.fileInput);
      }
      if (!(options.dropZone instanceof $)) {
        options.dropZone = $(options.dropZone);
      }
      if (!(options.pasteZone instanceof $)) {
        options.pasteZone = $(options.pasteZone);
      }
    },

    _getRegExp: function (str) {
      var parts = str.split('/'),
        modifiers = parts.pop();
      parts.shift();
      return new RegExp(parts.join('/'), modifiers);
    },

    _isRegExpOption: function (key, value) {
      return key !== 'url' && $.type(value) === 'string' &&
        /^\/.*\/[igm]{0,3}$/.test(value);
    },

    _initDataAttributes: function () {
      var that = this,
        options = this.options,
        data = this.element.data();
      $.each(
        this.element[0].attributes,
        function (index, attr) {
          var key = attr.name.toLowerCase(),
            value;
          if (/^data-/.test(key)) {
            key = key.slice(5).replace(/-[a-z]/g, function (str) {
              return str.charAt(1).toUpperCase();
            });
            value = data[key];
            if (that._isRegExpOption(key, value)) {
              value = that._getRegExp(value);
            }
            options[key] = value;
          }
        }
      );
    },

    _create: function () {
      this._initDataAttributes();
      this._initSpecialOptions();
      this._slots = [];
      this._sequence = this._getXHRPromise(true);
      this._sending = this._active = 0;
      this._initProgressObject(this);
      this._initEventHandlers();
    },

    active: function () {
      return this._active;
    },

    progress: function () {
      return this._progress;
    },

    add: function (data) {
      var that = this;
      if (!data || this.options.disabled) {
        return;
      }
      if (data.fileInput && !data.files) {
        this._getFileInputFiles(data.fileInput).always(function (files) {
          data.files = files;
          that._onAdd(null, data);
        });
      } else {
        data.files = $.makeArray(data.files);
        this._onAdd(null, data);
      }
    },

    send: function (data) {
      if (data && !this.options.disabled) {
        if (data.fileInput && !data.files) {
          var that = this,
            dfd = $.Deferred(),
            promise = dfd.promise(),
            jqXHR,
            aborted;
          promise.abort = function () {
            aborted = true;
            if (jqXHR) {
              return jqXHR.abort();
            }
            dfd.reject(null, 'abort', 'abort');
            return promise;
          };
          this._getFileInputFiles(data.fileInput).always(
            function (files) {
              if (aborted) {
                return;
              }
              if (!files.length) {
                dfd.reject();
                return;
              }
              data.files = files;
              jqXHR = that._onSend(null, data);
              jqXHR.then(
                function (result, textStatus, jqXHR) {
                  dfd.resolve(result, textStatus, jqXHR);
                },
                function (jqXHR, textStatus, errorThrown) {
                  dfd.reject(jqXHR, textStatus, errorThrown);
                }
              );
            }
          );
          return this._enhancePromise(promise);
        }
        data.files = $.makeArray(data.files);
        if (data.files.length) {
          return this._onSend(null, data);
        }
      }
      return this._getXHRPromise(false, data && data.context);
    }

  });

}));

################################################################################
__JQUERYKNOBJS__
/*!jQuery Knob*/
/**
 * Downward compatible, touchable dial
 *
 * Version: 1.2.0 (15/07/2012)
 * Requires: jQuery v1.7+
 *
 * Copyright (c) 2012 Anthony Terrien
 * Under MIT and GPL licenses:
 *  http://www.opensource.org/licenses/mit-license.php
 *  http://www.gnu.org/licenses/gpl.html
 *
 * Thanks to vor, eskimoblood, spiffistan, FabrizioC
 */
(function($) {

  /**
   * Kontrol library
   */
  "use strict";

  /**
   * Definition of globals and core
   */
  var k = {}, // kontrol
    max = Math.max,
    min = Math.min;

  k.c = {};
  k.c.d = $(document);
  k.c.t = function (e) {
    return e.originalEvent.touches.length - 1;
  };

  /**
   * Kontrol Object
   *
   * Definition of an abstract UI control
   *
   * Each concrete component must call this one.
   * <code>
   * k.o.call(this);
   * </code>
   */
  k.o = function () {
    var s = this;

    this.o = null; // array of options
    this.$ = null; // jQuery wrapped element
    this.i = null; // mixed HTMLInputElement or array of HTMLInputElement
    this.g = null; // 2D graphics context for 'pre-rendering'
    this.v = null; // value ; mixed array or integer
    this.cv = null; // change value ; not commited value
    this.x = 0; // canvas x position
    this.y = 0; // canvas y position
    this.$c = null; // jQuery canvas element
    this.c = null; // rendered canvas context
    this.t = 0; // touches index
    this.isInit = false;
    this.fgColor = null; // main color
    this.pColor = null; // previous color
    this.dH = null; // draw hook
    this.cH = null; // change hook
    this.eH = null; // cancel hook
    this.rH = null; // release hook

    this.run = function () {
      var cf = function (e, conf) {
        var k;
        for (k in conf) {
          s.o[k] = conf[k];
        }
        s.init();
        s._configure()
         ._draw();
      };

      if(this.$.data('kontroled')) return;
      this.$.data('kontroled', true);

      this.extend();
      this.o = $.extend(
        {
          // Config
          min : this.$.data('min') || 0,
          max : this.$.data('max') || 100,
          stopper : true,
          readOnly : this.$.data('readonly'),

          // UI
          cursor : (this.$.data('cursor') === true && 30)
                || this.$.data('cursor')
                || 0,
          thickness : this.$.data('thickness') || 0.35,
          lineCap : this.$.data('linecap') || 'butt',
          width : this.$.data('width') || 200,
          height : this.$.data('height') || 200,
          displayInput : this.$.data('displayinput') == null || this.$.data('displayinput'),
          displayPrevious : this.$.data('displayprevious'),
          fgColor : this.$.data('fgcolor') || '#87CEEB',
          inputColor: this.$.data('inputcolor') || this.$.data('fgcolor') || '#87CEEB',
          inline : false,
          step : this.$.data('step') || 1,

          // Hooks
          draw : null, // function () {}
          change : null, // function (value) {}
          cancel : null, // function () {}
          release : null // function (value) {}
        }, this.o
      );

      // routing value
      if(this.$.is('fieldset')) {

        // fieldset = array of integer
        this.v = {};
        this.i = this.$.find('input')
        this.i.each(function(k) {
          var $this = $(this);
          s.i[k] = $this;
          s.v[k] = $this.val();

          $this.bind(
            'change'
            , function () {
              var val = {};
              val[k] = $this.val();
              s.val(val);
            }
          );
        });
        this.$.find('legend').remove();

      } else {
        // input = integer
        this.i = this.$;
        this.v = this.$.val();
        (this.v == '') && (this.v = this.o.min);

        this.$.bind(
          'change'
          , function () {
            s.val(s._validate(s.$.val()));
          }
        );
      }

      (!this.o.displayInput) && this.$.hide();

      this.$c = $('<canvas width="' +
              this.o.width + 'px" height="' +
              this.o.height + 'px"></canvas>');
      this.c = this.$c[0].getContext("2d");

      this.$
        .wrap($('<div style="' + (this.o.inline ? 'display:inline;' : '') +
            'width:' + this.o.width + 'px;height:' +
            this.o.height + 'px;"></div>'))
        .before(this.$c);

      if (this.v instanceof Object) {
        this.cv = {};
        this.copy(this.v, this.cv);
      } else {
        this.cv = this.v;
      }

      this.$
        .bind("configure", cf)
        .parent()
        .bind("configure", cf);

      this._listen()
        ._configure()
        ._xy()
        .init();

      this.isInit = true;

      this._draw();

      return this;
    };

    this._draw = function () {

      // canvas pre-rendering
      var d = true,
        c = document.createElement('canvas');

      c.width = s.o.width;
      c.height = s.o.height;
      s.g = c.getContext('2d');

      s.clear();

      s.dH
      && (d = s.dH());

      (d !== false) && s.draw();

      s.c.drawImage(c, 0, 0);
      c = null;
    };

    this._touch = function (e) {

      var touchMove = function (e) {

        var v = s.xy2val(
              e.originalEvent.touches[s.t].pageX,
              e.originalEvent.touches[s.t].pageY
              );

        if (v == s.cv) return;

        if (
          s.cH
          && (s.cH(v) === false)
        ) return;


        s.change(s._validate(v));
        s._draw();
      };

      // get touches index
      this.t = k.c.t(e);

      // First touch
      touchMove(e);

      // Touch events listeners
      k.c.d
        .bind("touchmove.k", touchMove)
        .bind(
          "touchend.k"
          , function () {
            k.c.d.unbind('touchmove.k touchend.k');

            if (
              s.rH
              && (s.rH(s.cv) === false)
            ) return;

            s.val(s.cv);
          }
        );

      return this;
    };

    this._mouse = function (e) {

      var mouseMove = function (e) {
        var v = s.xy2val(e.pageX, e.pageY);
        if (v == s.cv) return;

        if (
          s.cH
          && (s.cH(v) === false)
        ) return;

        s.change(s._validate(v));
        s._draw();
      };

      // First click
      mouseMove(e);

      // Mouse events listeners
      k.c.d
        .bind("mousemove.k", mouseMove)
        .bind(
          // Escape key cancel current change
          "keyup.k"
          , function (e) {
            if (e.keyCode === 27) {
              k.c.d.unbind("mouseup.k mousemove.k keyup.k");

              if (
                s.eH
                && (s.eH() === false)
              ) return;

              s.cancel();
            }
          }
        )
        .bind(
          "mouseup.k"
          , function (e) {
            k.c.d.unbind('mousemove.k mouseup.k keyup.k');

            if (
              s.rH
              && (s.rH(s.cv) === false)
            ) return;

            s.val(s.cv);
          }
        );

      return this;
    };

    this._xy = function () {
      var o = this.$c.offset();
      this.x = o.left;
      this.y = o.top;
      return this;
    };

    this._listen = function () {

      if (!this.o.readOnly) {
        this.$c
          .bind(
            "mousedown"
            , function (e) {
              e.preventDefault();
              s._xy()._mouse(e);
             }
          )
          .bind(
            "touchstart"
            , function (e) {
              e.preventDefault();
              s._xy()._touch(e);
             }
          );
        this.listen();
      } else {
        this.$.attr('readonly', 'readonly');
      }

      return this;
    };

    this._configure = function () {

      // Hooks
      if (this.o.draw) this.dH = this.o.draw;
      if (this.o.change) this.cH = this.o.change;
      if (this.o.cancel) this.eH = this.o.cancel;
      if (this.o.release) this.rH = this.o.release;

      if (this.o.displayPrevious) {
        this.pColor = this.h2rgba(this.o.fgColor, "0.4");
        this.fgColor = this.h2rgba(this.o.fgColor, "0.6");
      } else {
        this.fgColor = this.o.fgColor;
      }

      return this;
    };

    this._clear = function () {
      this.$c[0].width = this.$c[0].width;
    };

    this._validate = function(v) {
      return (~~ (((v < 0) ? -0.5 : 0.5) + (v/this.o.step))) * this.o.step;
    };

    // Abstract methods
    this.listen = function () {}; // on start, one time
    this.extend = function () {}; // each time configure triggered
    this.init = function () {}; // each time configure triggered
    this.change = function (v) {}; // on change
    this.val = function (v) {}; // on release
    this.xy2val = function (x, y) {}; //
    this.draw = function () {}; // on change / on release
    this.clear = function () { this._clear(); };

    // Utils
    this.h2rgba = function (h, a) {
      var rgb;
      h = h.substring(1,7)
      rgb = [parseInt(h.substring(0,2),16)
           ,parseInt(h.substring(2,4),16)
           ,parseInt(h.substring(4,6),16)];
      return "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + "," + a + ")";
    };

    this.copy = function (f, t) {
      for (var i in f) { t[i] = f[i]; }
    };
  };


  /**
   * k.Dial
   */
  k.Dial = function () {
    k.o.call(this);

    this.startAngle = null;
    this.xy = null;
    this.radius = null;
    this.lineWidth = null;
    this.cursorExt = null;
    this.w2 = null;
    this.PI2 = 2*Math.PI;

    this.extend = function () {
      this.o = $.extend(
        {
          bgColor : this.$.data('bgcolor') || '#EEEEEE',
          angleOffset : this.$.data('angleoffset') || 0,
          angleArc : this.$.data('anglearc') || 360,
          inline : true
        }, this.o
      );
    };

    this.val = function (v) {
      if (null != v) {
        this.cv = this.o.stopper ? max(min(v, this.o.max), this.o.min) : v;
        this.v = this.cv;
        this.$.val(this.v);
        this._draw();
      } else {
        return this.v;
      }
    };

    this.xy2val = function (x, y) {
      var a, ret;

      a = Math.atan2(
            x - (this.x + this.w2)
            , - (y - this.y - this.w2)
          ) - this.angleOffset;

      if(this.angleArc != this.PI2 && (a < 0) && (a > -0.5)) {
        // if isset angleArc option, set to min if .5 under min
        a = 0;
      } else if (a < 0) {
        a += this.PI2;
      }

      ret = ~~ (0.5 + (a * (this.o.max - this.o.min) / this.angleArc))
          + this.o.min;

      this.o.stopper
      && (ret = max(min(ret, this.o.max), this.o.min));

      return ret;
    };

    this.listen = function () {
      // bind MouseWheel
      var s = this,
        mw = function (e) {
              e.preventDefault();
              var ori = e.originalEvent
                ,deltaX = ori.detail || ori.wheelDeltaX
                ,deltaY = ori.detail || ori.wheelDeltaY
                ,v = parseInt(s.$.val()) + (deltaX>0 || deltaY>0 ? s.o.step : deltaX<0 || deltaY<0 ? -s.o.step : 0);

              if (
                s.cH
                && (s.cH(v) === false)
              ) return;

              s.val(v);
            }
        , kval, to, m = 1, kv = {37:-s.o.step, 38:s.o.step, 39:s.o.step, 40:-s.o.step};

      this.$
        .bind(
          "keydown"
          ,function (e) {
            var kc = e.keyCode;

            // numpad support
            if(kc >= 96 && kc <= 105) {
              kc = e.keyCode = kc - 48;
            }

            kval = parseInt(String.fromCharCode(kc));

            if (isNaN(kval)) {

              (kc !== 13)     // enter
              && (kc !== 8)     // bs
              && (kc !== 9)     // tab
              && (kc !== 189)   // -
              && e.preventDefault();

              // arrows
              if ($.inArray(kc,[37,38,39,40]) > -1) {
                e.preventDefault();

                var v = parseInt(s.$.val()) + kv[kc] * m;

                s.o.stopper
                && (v = max(min(v, s.o.max), s.o.min));

                s.change(v);
                s._draw();

                // long time keydown speed-up
                to = window.setTimeout(
                  function () { m*=2; }
                  ,30
                );
              }
            }
          }
        )
        .bind(
          "keyup"
          ,function (e) {
            if (isNaN(kval)) {
              if (to) {
                window.clearTimeout(to);
                to = null;
                m = 1;
                s.val(s.$.val());
              }
            } else {
              // kval postcond
              (s.$.val() > s.o.max && s.$.val(s.o.max))
              || (s.$.val() < s.o.min && s.$.val(s.o.min));
            }

          }
        );

      this.$c.bind("mousewheel DOMMouseScroll", mw);
      this.$.bind("mousewheel DOMMouseScroll", mw)
    };

    this.init = function () {

      if (
        this.v < this.o.min
        || this.v > this.o.max
      ) this.v = this.o.min;

      this.$.val(this.v);
      this.w2 = this.o.width / 2;
      this.cursorExt = this.o.cursor / 100;
      this.xy = this.w2;
      this.lineWidth = this.xy * this.o.thickness;
      this.lineCap = this.o.lineCap;
      this.radius = this.xy - this.lineWidth / 2;

      this.o.angleOffset
      && (this.o.angleOffset = isNaN(this.o.angleOffset) ? 0 : this.o.angleOffset);

      this.o.angleArc
      && (this.o.angleArc = isNaN(this.o.angleArc) ? this.PI2 : this.o.angleArc);

      // deg to rad
      this.angleOffset = this.o.angleOffset * Math.PI / 180;
      this.angleArc = this.o.angleArc * Math.PI / 180;

      // compute start and end angles
      this.startAngle = 1.5 * Math.PI + this.angleOffset;
      this.endAngle = 1.5 * Math.PI + this.angleOffset + this.angleArc;

      var s = max(
              String(Math.abs(this.o.max)).length
              , String(Math.abs(this.o.min)).length
              , 2
              ) + 2;

      this.o.displayInput
        && this.i.css({
            'width' : ((this.o.width / 2 + 4) >> 0) + 'px'
            ,'height' : ((this.o.width / 3) >> 0) + 'px'
            ,'position' : 'absolute'
            ,'vertical-align' : 'middle'
            ,'margin-top' : ((this.o.width / 3) >> 0) + 'px'
            ,'margin-left' : '-' + ((this.o.width * 3 / 4 + 2) >> 0) + 'px'
            ,'border' : 0
            ,'background' : 'none'
            ,'font' : 'bold ' + ((this.o.width / s) >> 0) + 'px Arial'
            ,'text-align' : 'center'
            ,'color' : this.o.inputColor || this.o.fgColor
            ,'padding' : '0px'
            ,'-webkit-appearance': 'none'
            })
        || this.i.css({
            'width' : '0px'
            ,'visibility' : 'hidden'
            });
    };

    this.change = function (v) {
      this.cv = v;
      this.$.val(v);
    };

    this.angle = function (v) {
      return (v - this.o.min) * this.angleArc / (this.o.max - this.o.min);
    };

    this.draw = function () {

      var c = this.g,         // context
        a = this.angle(this.cv)  // Angle
        , sat = this.startAngle   // Start angle
        , eat = sat + a       // End angle
        , sa, ea          // Previous angles
        , r = 1;

      c.lineWidth = this.lineWidth;

      c.lineCap = this.lineCap;

      this.o.cursor
        && (sat = eat - this.cursorExt)
        && (eat = eat + this.cursorExt);

      c.beginPath();
        c.strokeStyle = this.o.bgColor;
        c.arc(this.xy, this.xy, this.radius, this.endAngle, this.startAngle, true);
      c.stroke();

      if (this.o.displayPrevious) {
        ea = this.startAngle + this.angle(this.v);
        sa = this.startAngle;
        this.o.cursor
          && (sa = ea - this.cursorExt)
          && (ea = ea + this.cursorExt);

        c.beginPath();
          c.strokeStyle = this.pColor;
          c.arc(this.xy, this.xy, this.radius, sa, ea, false);
        c.stroke();
        r = (this.cv == this.v);
      }

      c.beginPath();
        c.strokeStyle = r ? this.o.fgColor : this.fgColor ;
        c.arc(this.xy, this.xy, this.radius, sat, eat, false);
      c.stroke();
    };

    this.cancel = function () {
      this.val(this.v);
    };
  };

  $.fn.dial = $.fn.knob = function (o) {
    return this.each(
      function () {
        var d = new k.Dial();
        d.o = o;
        d.$ = $(this);
        d.run();
      }
    ).parent();
  };

})(jQuery);

################################################################################
__DOO__
#!/usr/bin/perl

opendir(my $dh, '.') || die;

while(readdir $dh) {
  $x = $_;

  if ($x eq "." or $x eq "..") {
    next;
  }

  $name = $x;
  $name =~ s/\.//g;

  print "__" . uc $name . "__\n";
  open(X, "<$x") or die "Can't find article $ARTICLE: $!\n";

  while (<X>) {
    print;
  }

  print "\n" . "#" x 80 . "\n";

}

closedir $dh;
################################################################################
__SCRIPTJS__
$(function(){

  var ul = $('#upload ul');

  $('#drop a').click(function(){
    $(this).parent().find('input').click();
  });

  $('#upload').fileupload({
    dataType : 'json',
//    dataType : 'text',
    autoUpload: true,
    dropZone: $('#drop'),

    add: function (e, data) {

var image_info = "";
image_info += "<p id='lat'>lat</p>";
image_info += "<p id='lon'>lon</p>";
image_info += "<p id='time'>time</p>";

var tpl_text = "";
tpl_text += "<li class='working'>";
tpl_text += "<div style='float:left; height:100px; background:magenta; margin:1px'>";
tpl_text += "<input type='text' value='0' data-width='48' data-height='48' data-fgColor='#0080a0' data-readOnly='1' data-bgColor='#404040' />";
tpl_text += "</div>";
tpl_text += "<div id='info' style='float:left; height:100px; background:green; margin:1px'>";
tpl_text += "</div>";
tpl_text += "<div style='float:left; height:100px; background:cyan; margin:1px'>";
tpl_text += "<span id='x'>In progress</span>";
tpl_text += "</div>";
tpl_text += "<br clear='all'>";
tpl_text += "</li>";

content = "<p>" + data.files[0].name + "<p>";
content += "<p>" + formatFileSize(data.files[0].size) + "</p>" + image_info;

      var tpl = $(tpl_text);

      tpl.find('div#info').html(content);

      // Add the HTML to the UL element
      data.context = tpl.appendTo(ul);

      // Initialize the knob plugin
      tpl.find('input').knob();

      // Listen for clicks on the cancel icon
      tpl.find('span#x').click(function(){

        if(tpl.hasClass('working')){
          jqXHR.abort();
        }

        tpl.fadeOut(function(){
          tpl.remove();
        });

      });

      // Automatically upload the file once it is added to the queue
      var jqXHR = data.submit();
    },

    progress: function(e, data){

      // Calculate the completion percentage of the upload
      var progress = parseInt(data.loaded / data.total * 100, 10);

      // Update the hidden input field and trigger a change
      // so that the jQuery knob plugin knows to update the dial
      data.context.find('input').val(progress).change();

      if (progress == 100){
        $('span#x').text("done");
      }
    },

    fail:function(e, data){
      // Something has gone wrong!
      data.context.addClass('error');
      alert('Fail!'+data.toString());
    },

    sent:function(e, data){
       alert('sent done');
    },

    uploaddone:function(e, data){
       alert('done');
    },

    stop:function(e, data){
       alert('stop');
    },

    always: function (e, data) {
//  alert(data.result.files[2].error);
      $('#lat').text(data.result.files[2].lat);
      $('#lon').text(data.result.files[2].lon);
      $('#time').text(data.result.files[2].time);
//      $('p').text(data.result.files[2].lat);
//  alert(data.textStatus);
  // data.jqXHR;
    }


  });

  $(document).on('drop dragover', function (e) {
    e.preventDefault();
  });

  function formatFileSize(bytes) {
    if (typeof bytes !== 'number') {
      return '';
    }

    if (bytes >= 1000000000) {
      return (bytes / 1000000000).toFixed(2) + ' GB';
    }

    if (bytes >= 1000000) {
      return (bytes / 1000000).toFixed(2) + ' MB';
    }

    return (bytes / 1000).toFixed(2) + ' KB';
  }

});

################################################################################
__JQUERYUIWIDGETJS__
/*
 * jQuery UI Widget 1.10.1+amd
 *
 * Copyright 2013 jQuery Foundation and other contributors
 * Released under the MIT license.
 *
 */

(function (factory) {
  if (typeof define === "function" && define.amd) {
    define(["jquery"], factory);
  } else {
    factory(jQuery);
  }
}(function( $, undefined ) {

var uuid = 0,
	slice = Array.prototype.slice,
	_cleanData = $.cleanData;
$.cleanData = function( elems ) {
	for ( var i = 0, elem; (elem = elems[i]) != null; i++ ) {
		try {
			$( elem ).triggerHandler( "remove" );
		} catch( e ) {}
	}
	_cleanData( elems );
};

$.widget = function( name, base, prototype ) {
	var fullName, existingConstructor, constructor, basePrototype,
		proxiedPrototype = {},
		namespace = name.split( "." )[ 0 ];

	name = name.split( "." )[ 1 ];
	fullName = namespace + "-" + name;

	if ( !prototype ) {
		prototype = base;
		base = $.Widget;
	}

	$.expr[ ":" ][ fullName.toLowerCase() ] = function( elem ) {
		return !!$.data( elem, fullName );
	};

	$[ namespace ] = $[ namespace ] || {};
	existingConstructor = $[ namespace ][ name ];
	constructor = $[ namespace ][ name ] = function( options, element ) {
		if ( !this._createWidget ) {
			return new constructor( options, element );
		}

		if ( arguments.length ) {
			this._createWidget( options, element );
		}
	};
	$.extend( constructor, existingConstructor, {
		version: prototype.version,
		_proto: $.extend( {}, prototype ),
		_childConstructors: []
	});

	basePrototype = new base();
	basePrototype.options = $.widget.extend( {}, basePrototype.options );
	$.each( prototype, function( prop, value ) {
		if ( !$.isFunction( value ) ) {
			proxiedPrototype[ prop ] = value;
			return;
		}
		proxiedPrototype[ prop ] = (function() {
			var _super = function() {
					return base.prototype[ prop ].apply( this, arguments );
				},
				_superApply = function( args ) {
					return base.prototype[ prop ].apply( this, args );
				};
			return function() {
				var __super = this._super,
					__superApply = this._superApply,
					returnValue;

				this._super = _super;
				this._superApply = _superApply;

				returnValue = value.apply( this, arguments );

				this._super = __super;
				this._superApply = __superApply;

				return returnValue;
			};
		})();
	});
	constructor.prototype = $.widget.extend( basePrototype, {
		widgetEventPrefix: existingConstructor ? basePrototype.widgetEventPrefix : name
	}, proxiedPrototype, {
		constructor: constructor,
		namespace: namespace,
		widgetName: name,
		widgetFullName: fullName
	});

	if ( existingConstructor ) {
		$.each( existingConstructor._childConstructors, function( i, child ) {
			var childPrototype = child.prototype;

			$.widget( childPrototype.namespace + "." + childPrototype.widgetName, constructor, child._proto );
		});
		delete existingConstructor._childConstructors;
	} else {
		base._childConstructors.push( constructor );
	}

	$.widget.bridge( name, constructor );
};

$.widget.extend = function( target ) {
	var input = slice.call( arguments, 1 ),
		inputIndex = 0,
		inputLength = input.length,
		key,
		value;
	for ( ; inputIndex < inputLength; inputIndex++ ) {
		for ( key in input[ inputIndex ] ) {
			value = input[ inputIndex ][ key ];
			if ( input[ inputIndex ].hasOwnProperty( key ) && value !== undefined ) {
				if ( $.isPlainObject( value ) ) {
					target[ key ] = $.isPlainObject( target[ key ] ) ?
						$.widget.extend( {}, target[ key ], value ) :
						$.widget.extend( {}, value );
				} else {
					target[ key ] = value;
				}
			}
		}
	}
	return target;
};

$.widget.bridge = function( name, object ) {
	var fullName = object.prototype.widgetFullName || name;
	$.fn[ name ] = function( options ) {
		var isMethodCall = typeof options === "string",
			args = slice.call( arguments, 1 ),
			returnValue = this;

		options = !isMethodCall && args.length ?
			$.widget.extend.apply( null, [ options ].concat(args) ) :
			options;

		if ( isMethodCall ) {
			this.each(function() {
				var methodValue,
					instance = $.data( this, fullName );
				if ( !instance ) {
					return $.error( "cannot call methods on " + name + " prior to initialization; " +
						"attempted to call method '" + options + "'" );
				}
				if ( !$.isFunction( instance[options] ) || options.charAt( 0 ) === "_" ) {
					return $.error( "no such method '" + options + "' for " + name + " widget instance" );
				}
				methodValue = instance[ options ].apply( instance, args );
				if ( methodValue !== instance && methodValue !== undefined ) {
					returnValue = methodValue && methodValue.jquery ?
						returnValue.pushStack( methodValue.get() ) :
						methodValue;
					return false;
				}
			});
		} else {
			this.each(function() {
				var instance = $.data( this, fullName );
				if ( instance ) {
					instance.option( options || {} )._init();
				} else {
					$.data( this, fullName, new object( options, this ) );
				}
			});
		}

		return returnValue;
	};
};

$.Widget = function( /* options, element */ ) {};
$.Widget._childConstructors = [];

$.Widget.prototype = {
	widgetName: "widget",
	widgetEventPrefix: "",
	defaultElement: "<div>",
	options: {
		disabled: false,

		create: null
	},
	_createWidget: function( options, element ) {
		element = $( element || this.defaultElement || this )[ 0 ];
		this.element = $( element );
		this.uuid = uuid++;
		this.eventNamespace = "." + this.widgetName + this.uuid;
		this.options = $.widget.extend( {},
			this.options,
			this._getCreateOptions(),
			options );

		this.bindings = $();
		this.hoverable = $();
		this.focusable = $();

		if ( element !== this ) {
			$.data( element, this.widgetFullName, this );
			this._on( true, this.element, {
				remove: function( event ) {
					if ( event.target === element ) {
						this.destroy();
					}
				}
			});
			this.document = $( element.style ?
				element.ownerDocument :
				element.document || element );
			this.window = $( this.document[0].defaultView || this.document[0].parentWindow );
		}

		this._create();
		this._trigger( "create", null, this._getCreateEventData() );
		this._init();
	},
	_getCreateOptions: $.noop,
	_getCreateEventData: $.noop,
	_create: $.noop,
	_init: $.noop,

	destroy: function() {
		this._destroy();
		this.element
			.unbind( this.eventNamespace )
			.removeData( this.widgetName )
			.removeData( this.widgetFullName )
			.removeData( $.camelCase( this.widgetFullName ) );
		this.widget()
			.unbind( this.eventNamespace )
			.removeAttr( "aria-disabled" )
			.removeClass(
				this.widgetFullName + "-disabled " +
				"ui-state-disabled" );

		this.bindings.unbind( this.eventNamespace );
		this.hoverable.removeClass( "ui-state-hover" );
		this.focusable.removeClass( "ui-state-focus" );
	},
	_destroy: $.noop,

	widget: function() {
		return this.element;
	},

	option: function( key, value ) {
		var options = key,
			parts,
			curOption,
			i;

		if ( arguments.length === 0 ) {
			return $.widget.extend( {}, this.options );
		}

		if ( typeof key === "string" ) {
			options = {};
			parts = key.split( "." );
			key = parts.shift();
			if ( parts.length ) {
				curOption = options[ key ] = $.widget.extend( {}, this.options[ key ] );
				for ( i = 0; i < parts.length - 1; i++ ) {
					curOption[ parts[ i ] ] = curOption[ parts[ i ] ] || {};
					curOption = curOption[ parts[ i ] ];
				}
				key = parts.pop();
				if ( value === undefined ) {
					return curOption[ key ] === undefined ? null : curOption[ key ];
				}
				curOption[ key ] = value;
			} else {
				if ( value === undefined ) {
					return this.options[ key ] === undefined ? null : this.options[ key ];
				}
				options[ key ] = value;
			}
		}

		this._setOptions( options );

		return this;
	},
	_setOptions: function( options ) {
		var key;

		for ( key in options ) {
			this._setOption( key, options[ key ] );
		}

		return this;
	},
	_setOption: function( key, value ) {
		this.options[ key ] = value;

		if ( key === "disabled" ) {
			this.widget()
				.toggleClass( this.widgetFullName + "-disabled ui-state-disabled", !!value )
				.attr( "aria-disabled", value );
			this.hoverable.removeClass( "ui-state-hover" );
			this.focusable.removeClass( "ui-state-focus" );
		}

		return this;
	},

	enable: function() {
		return this._setOption( "disabled", false );
	},
	disable: function() {
		return this._setOption( "disabled", true );
	},

	_on: function( suppressDisabledCheck, element, handlers ) {
		var delegateElement,
			instance = this;

		if ( typeof suppressDisabledCheck !== "boolean" ) {
			handlers = element;
			element = suppressDisabledCheck;
			suppressDisabledCheck = false;
		}

		if ( !handlers ) {
			handlers = element;
			element = this.element;
			delegateElement = this.widget();
		} else {
			element = delegateElement = $( element );
			this.bindings = this.bindings.add( element );
		}

		$.each( handlers, function( event, handler ) {
			function handlerProxy() {
				if ( !suppressDisabledCheck &&
						( instance.options.disabled === true ||
							$( this ).hasClass( "ui-state-disabled" ) ) ) {
					return;
				}
				return ( typeof handler === "string" ? instance[ handler ] : handler )
					.apply( instance, arguments );
			}

			if ( typeof handler !== "string" ) {
				handlerProxy.guid = handler.guid =
					handler.guid || handlerProxy.guid || $.guid++;
			}

			var match = event.match( /^(\w+)\s*(.*)$/ ),
				eventName = match[1] + instance.eventNamespace,
				selector = match[2];
			if ( selector ) {
				delegateElement.delegate( selector, eventName, handlerProxy );
			} else {
				element.bind( eventName, handlerProxy );
			}
		});
	},

	_off: function( element, eventName ) {
		eventName = (eventName || "").split( " " ).join( this.eventNamespace + " " ) + this.eventNamespace;
		element.unbind( eventName ).undelegate( eventName );
	},

	_delay: function( handler, delay ) {
		function handlerProxy() {
			return ( typeof handler === "string" ? instance[ handler ] : handler )
				.apply( instance, arguments );
		}
		var instance = this;
		return setTimeout( handlerProxy, delay || 0 );
	},

	_hoverable: function( element ) {
		this.hoverable = this.hoverable.add( element );
		this._on( element, {
			mouseenter: function( event ) {
				$( event.currentTarget ).addClass( "ui-state-hover" );
			},
			mouseleave: function( event ) {
				$( event.currentTarget ).removeClass( "ui-state-hover" );
			}
		});
	},

	_focusable: function( element ) {
		this.focusable = this.focusable.add( element );
		this._on( element, {
			focusin: function( event ) {
				$( event.currentTarget ).addClass( "ui-state-focus" );
			},
			focusout: function( event ) {
				$( event.currentTarget ).removeClass( "ui-state-focus" );
			}
		});
	},

	_trigger: function( type, event, data ) {
		var prop, orig,
			callback = this.options[ type ];

		data = data || {};
		event = $.Event( event );
		event.type = ( type === this.widgetEventPrefix ?
			type :
			this.widgetEventPrefix + type ).toLowerCase();
		event.target = this.element[ 0 ];

		orig = event.originalEvent;
		if ( orig ) {
			for ( prop in orig ) {
				if ( !( prop in event ) ) {
					event[ prop ] = orig[ prop ];
				}
			}
		}

		this.element.trigger( event, data );
		return !( $.isFunction( callback ) &&
			callback.apply( this.element[0], [ event ].concat( data ) ) === false ||
			event.isDefaultPrevented() );
	}
};

$.each( { show: "fadeIn", hide: "fadeOut" }, function( method, defaultEffect ) {
	$.Widget.prototype[ "_" + method ] = function( element, options, callback ) {
		if ( typeof options === "string" ) {
			options = { effect: options };
		}
		var hasOptions,
			effectName = !options ?
				method :
				options === true || typeof options === "number" ?
					defaultEffect :
					options.effect || defaultEffect;
		options = options || {};
		if ( typeof options === "number" ) {
			options = { duration: options };
		}
		hasOptions = !$.isEmptyObject( options );
		options.complete = callback;
		if ( options.delay ) {
			element.delay( options.delay );
		}
		if ( hasOptions && $.effects && $.effects.effect[ effectName ] ) {
			element[ method ]( options );
		} else if ( effectName !== method && element[ effectName ] ) {
			element[ effectName ]( options.duration, options.easing, callback );
		} else {
			element.queue(function( next ) {
				$( this )[ method ]();
				if ( callback ) {
					callback.call( element[ 0 ] );
				}
				next();
			});
		}
	};
});

}));

################################################################################
__JQUERYIFRAME-TRANSPORTJS__
/*
 * jQuery Iframe Transport Plugin
 * https://github.com/blueimp/jQuery-File-Upload
 *
 * Copyright 2011, Sebastian Tschan
 * https://blueimp.net
 *
 * Licensed under the MIT license:
 * http://www.opensource.org/licenses/MIT
 */

/* global define, require, window, document */

(function (factory) {
  'use strict';
  if (typeof define === 'function' && define.amd) {
    // Register as an anonymous AMD module:
    define(['jquery'], factory);
  } else if (typeof exports === 'object') {
    // Node/CommonJS:
    factory(require('jquery'));
  } else {
    // Browser globals:
    factory(window.jQuery);
  }
}(function ($) {
  'use strict';

  // Helper variable to create unique names for the transport iframes:
  var counter = 0;

  // The iframe transport accepts four additional options:
  // options.fileInput: a jQuery collection of file input fields
  // options.paramName: the parameter name for the file form data,
  //  overrides the name property of the file input field(s),
  //  can be a string or an array of strings.
  // options.formData: an array of objects with name and value properties,
  //  equivalent to the return data of .serializeArray(), e.g.:
  //  [{name: 'a', value: 1}, {name: 'b', value: 2}]
  // options.initialIframeSrc: the URL of the initial iframe src,
  //  by default set to "javascript:false;"
  $.ajaxTransport('iframe', function (options) {
    if (options.async) {
      // javascript:false as initial iframe src
      // prevents warning popups on HTTPS in IE6:
      /*jshint scripturl: true */
      var initialIframeSrc = options.initialIframeSrc || 'javascript:false;',
      /*jshint scripturl: false */
        form,
        iframe,
        addParamChar;
      return {
        send: function (_, completeCallback) {
          form = $('<form style="display:none;"></form>');
          form.attr('accept-charset', options.formAcceptCharset);
          addParamChar = /\?/.test(options.url) ? '&' : '?';
          // XDomainRequest only supports GET and POST:
          if (options.type === 'DELETE') {
            options.url = options.url + addParamChar + '_method=DELETE';
            options.type = 'POST';
          } else if (options.type === 'PUT') {
            options.url = options.url + addParamChar + '_method=PUT';
            options.type = 'POST';
          } else if (options.type === 'PATCH') {
            options.url = options.url + addParamChar + '_method=PATCH';
            options.type = 'POST';
          }
          // IE versions below IE8 cannot set the name property of
          // elements that have already been added to the DOM,
          // so we set the name along with the iframe HTML markup:
          counter += 1;
          iframe = $(
            '<iframe src="' + initialIframeSrc +
              '" name="iframe-transport-' + counter + '"></iframe>'
          ).bind('load', function () {
            var fileInputClones,
              paramNames = $.isArray(options.paramName) ?
                  options.paramName : [options.paramName];
            iframe
              .unbind('load')
              .bind('load', function () {
                var response;
                // Wrap in a try/catch block to catch exceptions thrown
                // when trying to access cross-domain iframe contents:
                try {
                  response = iframe.contents();
                  // Google Chrome and Firefox do not throw an
                  // exception when calling iframe.contents() on
                  // cross-domain requests, so we unify the response:
                  if (!response.length || !response[0].firstChild) {
                    throw new Error();
                  }
                } catch (e) {
                  response = undefined;
                }
                // The complete callback returns the
                // iframe content document as response object:
                completeCallback(
                  200,
                  'success',
                  {'iframe': response}
                );
                // Fix for IE endless progress bar activity bug
                // (happens on form submits to iframe targets):
                $('<iframe src="' + initialIframeSrc + '"></iframe>')
                  .appendTo(form);
                window.setTimeout(function () {
                  // Removing the form in a setTimeout call
                  // allows Chrome's developer tools to display
                  // the response result
                  form.remove();
                }, 0);
              });
            form
              .prop('target', iframe.prop('name'))
              .prop('action', options.url)
              .prop('method', options.type);
            if (options.formData) {
              $.each(options.formData, function (index, field) {
                $('<input type="hidden"/>')
                  .prop('name', field.name)
                  .val(field.value)
                  .appendTo(form);
              });
            }
            if (options.fileInput && options.fileInput.length &&
                options.type === 'POST') {
              fileInputClones = options.fileInput.clone();
              // Insert a clone for each file input field:
              options.fileInput.after(function (index) {
                return fileInputClones[index];
              });
              if (options.paramName) {
                options.fileInput.each(function (index) {
                  $(this).prop(
                    'name',
                    paramNames[index] || options.paramName
                  );
                });
              }
              // Appending the file input fields to the hidden form
              // removes them from their original location:
              form
                .append(options.fileInput)
                .prop('enctype', 'multipart/form-data')
                // enctype must be set as encoding for IE:
                .prop('encoding', 'multipart/form-data');
              // Remove the HTML5 form attribute from the input(s):
              options.fileInput.removeAttr('form');
            }
            form.submit();
            // Insert the file input fields at their original location
            // by replacing the clones with the originals:
            if (fileInputClones && fileInputClones.length) {
              options.fileInput.each(function (index, input) {
                var clone = $(fileInputClones[index]);
                // Restore the original name and form properties:
                $(input)
                  .prop('name', clone.prop('name'))
                  .attr('form', clone.attr('form'));
                clone.replaceWith(input);
              });
            }
          });
          form.append(iframe).appendTo(document.body);
        },
        abort: function () {
          if (iframe) {
            // javascript:false as iframe src aborts the request
            // and prevents warning popups on HTTPS in IE6.
            // concat is used to avoid the "Script URL" JSLint error:
            iframe
              .unbind('load')
              .prop('src', initialIframeSrc);
          }
          if (form) {
            form.remove();
          }
        }
      };
    }
  });

  // The iframe transport returns the iframe content document as response.
  // The following adds converters from iframe to text, json, html, xml
  // and script.
  // Please note that the Content-Type for JSON responses has to be text/plain
  // or text/html, if the browser doesn't include application/json in the
  // Accept header, else IE will show a download dialog.
  // The Content-Type for XML responses on the other hand has to be always
  // application/xml or text/xml, so IE properly parses the XML response.
  // See also
  // https://github.com/blueimp/jQuery-File-Upload/wiki/Setup#content-type-negotiation
  $.ajaxSetup({
    converters: {
      'iframe text': function (iframe) {
        return iframe && $(iframe[0].body).text();
      },
      'iframe json': function (iframe) {
        return iframe && $.parseJSON($(iframe[0].body).text());
      },
      'iframe html': function (iframe) {
        return iframe && $(iframe[0].body).html();
      },
      'iframe xml': function (iframe) {
        var xmlDoc = iframe && iframe[0];
        return xmlDoc && $.isXMLDoc(xmlDoc) ? xmlDoc :
            $.parseXML((xmlDoc.XMLDocument && xmlDoc.XMLDocument.xml) ||
              $(xmlDoc.body).html());
      },
      'iframe script': function (iframe) {
        return iframe && $.globalEval($(iframe[0].body).text());
      }
    }
  });

}));

################################################################################
__JQUERYFILEUPLOAD-UIJS__
/*
 * jQuery File Upload User Interface Plugin
 * https://github.com/blueimp/jQuery-File-Upload
 *
 * Copyright 2010, Sebastian Tschan
 * https://blueimp.net
 *
 * Licensed under the MIT license:
 * http://www.opensource.org/licenses/MIT
 */

/* jshint nomen:false */
/* global define, require, window */

(function (factory) {
    'use strict';
    if (typeof define === 'function' && define.amd) {
        // Register as an anonymous AMD module:
        define([
            'jquery',
            'tmpl',
            './jquery.fileupload-image',
            './jquery.fileupload-audio',
            './jquery.fileupload-video',
            './jquery.fileupload-validate'
        ], factory);
    } else if (typeof exports === 'object') {
        // Node/CommonJS:
        factory(
            require('jquery'),
            require('tmpl')
        );
    } else {
        // Browser globals:
        factory(
            window.jQuery,
            window.tmpl
        );
    }
}(function ($, tmpl) {
    'use strict';

    $.blueimp.fileupload.prototype._specialOptions.push(
        'filesContainer',
        'uploadTemplateId',
        'downloadTemplateId'
    );

    // The UI version extends the file upload widget
    // and adds complete user interface interaction:
    $.widget('blueimp.fileupload', $.blueimp.fileupload, {

        options: {
            // By default, files added to the widget are uploaded as soon
            // as the user clicks on the start buttons. To enable automatic
            // uploads, set the following option to true:
            autoUpload: false,
            // The ID of the upload template:
            uploadTemplateId: 'template-upload',
            // The ID of the download template:
            downloadTemplateId: 'template-download',
            // The container for the list of files. If undefined, it is set to
            // an element with class "files" inside of the widget element:
            filesContainer: undefined,
            // By default, files are appended to the files container.
            // Set the following option to true, to prepend files instead:
            prependFiles: false,
            // The expected data type of the upload response, sets the dataType
            // option of the $.ajax upload requests:
            dataType: 'json',

            // Error and info messages:
            messages: {
                unknownError: 'Unknown error'
            },

            // Function returning the current number of files,
            // used by the maxNumberOfFiles validation:
            getNumberOfFiles: function () {
                return this.filesContainer.children()
                    .not('.processing').length;
            },

            // Callback to retrieve the list of files from the server response:
            getFilesFromResponse: function (data) {
                if (data.result && $.isArray(data.result.files)) {
                    return data.result.files;
                }
                return [];
            },

            // The add callback is invoked as soon as files are added to the fileupload
            // widget (via file input selection, drag & drop or add API call).
            // See the basic file upload widget for more information:
            add: function (e, data) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var $this = $(this),
                    that = $this.data('blueimp-fileupload') ||
                        $this.data('fileupload'),
                    options = that.options;
                data.context = that._renderUpload(data.files)
                    .data('data', data)
                    .addClass('processing');
                options.filesContainer[
                    options.prependFiles ? 'prepend' : 'append'
                ](data.context);
                that._forceReflow(data.context);
                that._transition(data.context);
                data.process(function () {
                    return $this.fileupload('process', data);
                }).always(function () {
                    data.context.each(function (index) {
                        $(this).find('.size').text(
                            that._formatFileSize(data.files[index].size)
                        );
                    }).removeClass('processing');
                    that._renderPreviews(data);
                }).done(function () {
                    data.context.find('.start').prop('disabled', false);
                    if ((that._trigger('added', e, data) !== false) &&
                            (options.autoUpload || data.autoUpload) &&
                            data.autoUpload !== false) {
                        data.submit();
                    }
                }).fail(function () {
                    if (data.files.error) {
                        data.context.each(function (index) {
                            var error = data.files[index].error;
                            if (error) {
                                $(this).find('.error').text(error);
                            }
                        });
                    }
                });
            },
            // Callback for the start of each file upload request:
            send: function (e, data) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var that = $(this).data('blueimp-fileupload') ||
                        $(this).data('fileupload');
                if (data.context && data.dataType &&
                        data.dataType.substr(0, 6) === 'iframe') {
                    // Iframe Transport does not support progress events.
                    // In lack of an indeterminate progress bar, we set
                    // the progress to 100%, showing the full animated bar:
                    data.context
                        .find('.progress').addClass(
                            !$.support.transition && 'progress-animated'
                        )
                        .attr('aria-valuenow', 100)
                        .children().first().css(
                            'width',
                            '100%'
                        );
                }
                return that._trigger('sent', e, data);
            },
            // Callback for successful uploads:
            done: function (e, data) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var that = $(this).data('blueimp-fileupload') ||
                        $(this).data('fileupload'),
                    getFilesFromResponse = data.getFilesFromResponse ||
                        that.options.getFilesFromResponse,
                    files = getFilesFromResponse(data),
                    template,
                    deferred;
                if (data.context) {
                    data.context.each(function (index) {
                        var file = files[index] ||
                                {error: 'Empty file upload result'};
                        deferred = that._addFinishedDeferreds();
                        that._transition($(this)).done(
                            function () {
                                var node = $(this);
                                template = that._renderDownload([file])
                                    .replaceAll(node);
                                that._forceReflow(template);
                                that._transition(template).done(
                                    function () {
                                        data.context = $(this);
                                        that._trigger('completed', e, data);
                                        that._trigger('finished', e, data);
                                        deferred.resolve();
                                    }
                                );
                            }
                        );
                    });
                } else {
                    template = that._renderDownload(files)[
                        that.options.prependFiles ? 'prependTo' : 'appendTo'
                    ](that.options.filesContainer);
                    that._forceReflow(template);
                    deferred = that._addFinishedDeferreds();
                    that._transition(template).done(
                        function () {
                            data.context = $(this);
                            that._trigger('completed', e, data);
                            that._trigger('finished', e, data);
                            deferred.resolve();
                        }
                    );
                }
            },
            // Callback for failed (abort or error) uploads:
            fail: function (e, data) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var that = $(this).data('blueimp-fileupload') ||
                        $(this).data('fileupload'),
                    template,
                    deferred;
                if (data.context) {
                    data.context.each(function (index) {
                        if (data.errorThrown !== 'abort') {
                            var file = data.files[index];
                            file.error = file.error || data.errorThrown ||
                                data.i18n('unknownError');
                            deferred = that._addFinishedDeferreds();
                            that._transition($(this)).done(
                                function () {
                                    var node = $(this);
                                    template = that._renderDownload([file])
                                        .replaceAll(node);
                                    that._forceReflow(template);
                                    that._transition(template).done(
                                        function () {
                                            data.context = $(this);
                                            that._trigger('failed', e, data);
                                            that._trigger('finished', e, data);
                                            deferred.resolve();
                                        }
                                    );
                                }
                            );
                        } else {
                            deferred = that._addFinishedDeferreds();
                            that._transition($(this)).done(
                                function () {
                                    $(this).remove();
                                    that._trigger('failed', e, data);
                                    that._trigger('finished', e, data);
                                    deferred.resolve();
                                }
                            );
                        }
                    });
                } else if (data.errorThrown !== 'abort') {
                    data.context = that._renderUpload(data.files)[
                        that.options.prependFiles ? 'prependTo' : 'appendTo'
                    ](that.options.filesContainer)
                        .data('data', data);
                    that._forceReflow(data.context);
                    deferred = that._addFinishedDeferreds();
                    that._transition(data.context).done(
                        function () {
                            data.context = $(this);
                            that._trigger('failed', e, data);
                            that._trigger('finished', e, data);
                            deferred.resolve();
                        }
                    );
                } else {
                    that._trigger('failed', e, data);
                    that._trigger('finished', e, data);
                    that._addFinishedDeferreds().resolve();
                }
            },
            // Callback for upload progress events:
            progress: function (e, data) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var progress = Math.floor(data.loaded / data.total * 100);
                if (data.context) {
                    data.context.each(function () {
                        $(this).find('.progress')
                            .attr('aria-valuenow', progress)
                            .children().first().css(
                                'width',
                                progress + '%'
                            );
                    });
                }
            },
            // Callback for global upload progress events:
            progressall: function (e, data) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var $this = $(this),
                    progress = Math.floor(data.loaded / data.total * 100),
                    globalProgressNode = $this.find('.fileupload-progress'),
                    extendedProgressNode = globalProgressNode
                        .find('.progress-extended');
                if (extendedProgressNode.length) {
                    extendedProgressNode.html(
                        ($this.data('blueimp-fileupload') || $this.data('fileupload'))
                            ._renderExtendedProgress(data)
                    );
                }
                globalProgressNode
                    .find('.progress')
                    .attr('aria-valuenow', progress)
                    .children().first().css(
                        'width',
                        progress + '%'
                    );
            },
            // Callback for uploads start, equivalent to the global ajaxStart event:
            start: function (e) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var that = $(this).data('blueimp-fileupload') ||
                        $(this).data('fileupload');
                that._resetFinishedDeferreds();
                that._transition($(this).find('.fileupload-progress')).done(
                    function () {
                        that._trigger('started', e);
                    }
                );
            },
            // Callback for uploads stop, equivalent to the global ajaxStop event:
            stop: function (e) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var that = $(this).data('blueimp-fileupload') ||
                        $(this).data('fileupload'),
                    deferred = that._addFinishedDeferreds();
                $.when.apply($, that._getFinishedDeferreds())
                    .done(function () {
                        that._trigger('stopped', e);
                    });
                that._transition($(this).find('.fileupload-progress')).done(
                    function () {
                        $(this).find('.progress')
                            .attr('aria-valuenow', '0')
                            .children().first().css('width', '0%');
                        $(this).find('.progress-extended').html('&nbsp;');
                        deferred.resolve();
                    }
                );
            },
            processstart: function (e) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                $(this).addClass('fileupload-processing');
            },
            processstop: function (e) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                $(this).removeClass('fileupload-processing');
            },
            // Callback for file deletion:
            destroy: function (e, data) {
                if (e.isDefaultPrevented()) {
                    return false;
                }
                var that = $(this).data('blueimp-fileupload') ||
                        $(this).data('fileupload'),
                    removeNode = function () {
                        that._transition(data.context).done(
                            function () {
                                $(this).remove();
                                that._trigger('destroyed', e, data);
                            }
                        );
                    };
                if (data.url) {
                    data.dataType = data.dataType || that.options.dataType;
                    $.ajax(data).done(removeNode).fail(function () {
                        that._trigger('destroyfailed', e, data);
                    });
                } else {
                    removeNode();
                }
            }
        },

        _resetFinishedDeferreds: function () {
            this._finishedUploads = [];
        },

        _addFinishedDeferreds: function (deferred) {
            if (!deferred) {
                deferred = $.Deferred();
            }
            this._finishedUploads.push(deferred);
            return deferred;
        },

        _getFinishedDeferreds: function () {
            return this._finishedUploads;
        },

        // Link handler, that allows to download files
        // by drag & drop of the links to the desktop:
        _enableDragToDesktop: function () {
            var link = $(this),
                url = link.prop('href'),
                name = link.prop('download'),
                type = 'application/octet-stream';
            link.bind('dragstart', function (e) {
                try {
                    e.originalEvent.dataTransfer.setData(
                        'DownloadURL',
                        [type, name, url].join(':')
                    );
                } catch (ignore) {}
            });
        },

        _formatFileSize: function (bytes) {
            if (typeof bytes !== 'number') {
                return '';
            }
            if (bytes >= 1000000000) {
                return (bytes / 1000000000).toFixed(2) + ' GB';
            }
            if (bytes >= 1000000) {
                return (bytes / 1000000).toFixed(2) + ' MB';
            }
            return (bytes / 1000).toFixed(2) + ' KB';
        },

        _formatBitrate: function (bits) {
            if (typeof bits !== 'number') {
                return '';
            }
            if (bits >= 1000000000) {
                return (bits / 1000000000).toFixed(2) + ' Gbit/s';
            }
            if (bits >= 1000000) {
                return (bits / 1000000).toFixed(2) + ' Mbit/s';
            }
            if (bits >= 1000) {
                return (bits / 1000).toFixed(2) + ' kbit/s';
            }
            return bits.toFixed(2) + ' bit/s';
        },

        _formatTime: function (seconds) {
            var date = new Date(seconds * 1000),
                days = Math.floor(seconds / 86400);
            days = days ? days + 'd ' : '';
            return days +
                ('0' + date.getUTCHours()).slice(-2) + ':' +
                ('0' + date.getUTCMinutes()).slice(-2) + ':' +
                ('0' + date.getUTCSeconds()).slice(-2);
        },

        _formatPercentage: function (floatValue) {
            return (floatValue * 100).toFixed(2) + ' %';
        },

        _renderExtendedProgress: function (data) {
            return this._formatBitrate(data.bitrate) + ' | ' +
                this._formatTime(
                    (data.total - data.loaded) * 8 / data.bitrate
                ) + ' | ' +
                this._formatPercentage(
                    data.loaded / data.total
                ) + ' | ' +
                this._formatFileSize(data.loaded) + ' / ' +
                this._formatFileSize(data.total);
        },

        _renderTemplate: function (func, files) {
            if (!func) {
                return $();
            }
            var result = func({
                files: files,
                formatFileSize: this._formatFileSize,
                options: this.options
            });
            if (result instanceof $) {
                return result;
            }
            return $(this.options.templatesContainer).html(result).children();
        },

        _renderPreviews: function (data) {
            data.context.find('.preview').each(function (index, elm) {
                $(elm).append(data.files[index].preview);
            });
        },

        _renderUpload: function (files) {
            return this._renderTemplate(
                this.options.uploadTemplate,
                files
            );
        },

        _renderDownload: function (files) {
            return this._renderTemplate(
                this.options.downloadTemplate,
                files
            ).find('a[download]').each(this._enableDragToDesktop).end();
        },

        _startHandler: function (e) {
            e.preventDefault();
            var button = $(e.currentTarget),
                template = button.closest('.template-upload'),
                data = template.data('data');
            button.prop('disabled', true);
            if (data && data.submit) {
                data.submit();
            }
        },

        _cancelHandler: function (e) {
            e.preventDefault();
            var template = $(e.currentTarget)
                    .closest('.template-upload,.template-download'),
                data = template.data('data') || {};
            data.context = data.context || template;
            if (data.abort) {
                data.abort();
            } else {
                data.errorThrown = 'abort';
                this._trigger('fail', e, data);
            }
        },

        _deleteHandler: function (e) {
            e.preventDefault();
            var button = $(e.currentTarget);
            this._trigger('destroy', e, $.extend({
                context: button.closest('.template-download'),
                type: 'DELETE'
            }, button.data()));
        },

        _forceReflow: function (node) {
            return $.support.transition && node.length &&
                node[0].offsetWidth;
        },

        _transition: function (node) {
            var dfd = $.Deferred();
            if ($.support.transition && node.hasClass('fade') && node.is(':visible')) {
                node.bind(
                    $.support.transition.end,
                    function (e) {
                        // Make sure we don't respond to other transitions events
                        // in the container element, e.g. from button elements:
                        if (e.target === node[0]) {
                            node.unbind($.support.transition.end);
                            dfd.resolveWith(node);
                        }
                    }
                ).toggleClass('in');
            } else {
                node.toggleClass('in');
                dfd.resolveWith(node);
            }
            return dfd;
        },

        _initButtonBarEventHandlers: function () {
            var fileUploadButtonBar = this.element.find('.fileupload-buttonbar'),
                filesList = this.options.filesContainer;
            this._on(fileUploadButtonBar.find('.start'), {
                click: function (e) {
                    e.preventDefault();
                    filesList.find('.start').click();
                }
            });
            this._on(fileUploadButtonBar.find('.cancel'), {
                click: function (e) {
                    e.preventDefault();
                    filesList.find('.cancel').click();
                }
            });
            this._on(fileUploadButtonBar.find('.delete'), {
                click: function (e) {
                    e.preventDefault();
                    filesList.find('.toggle:checked')
                        .closest('.template-download')
                        .find('.delete').click();
                    fileUploadButtonBar.find('.toggle')
                        .prop('checked', false);
                }
            });
            this._on(fileUploadButtonBar.find('.toggle'), {
                change: function (e) {
                    filesList.find('.toggle').prop(
                        'checked',
                        $(e.currentTarget).is(':checked')
                    );
                }
            });
        },

        _destroyButtonBarEventHandlers: function () {
            this._off(
                this.element.find('.fileupload-buttonbar')
                    .find('.start, .cancel, .delete'),
                'click'
            );
            this._off(
                this.element.find('.fileupload-buttonbar .toggle'),
                'change.'
            );
        },

        _initEventHandlers: function () {
            this._super();
            this._on(this.options.filesContainer, {
                'click .start': this._startHandler,
                'click .cancel': this._cancelHandler,
                'click .delete': this._deleteHandler
            });
            this._initButtonBarEventHandlers();
        },

        _destroyEventHandlers: function () {
            this._destroyButtonBarEventHandlers();
            this._off(this.options.filesContainer, 'click');
            this._super();
        },

        _enableFileInputButton: function () {
            this.element.find('.fileinput-button input')
                .prop('disabled', false)
                .parent().removeClass('disabled');
        },

        _disableFileInputButton: function () {
            this.element.find('.fileinput-button input')
                .prop('disabled', true)
                .parent().addClass('disabled');
        },

        _initTemplates: function () {
            var options = this.options;
            options.templatesContainer = this.document[0].createElement(
                options.filesContainer.prop('nodeName')
            );
            if (tmpl) {
                if (options.uploadTemplateId) {
                    options.uploadTemplate = tmpl(options.uploadTemplateId);
                }
                if (options.downloadTemplateId) {
                    options.downloadTemplate = tmpl(options.downloadTemplateId);
                }
            }
        },

        _initFilesContainer: function () {
            var options = this.options;
            if (options.filesContainer === undefined) {
                options.filesContainer = this.element.find('.files');
            } else if (!(options.filesContainer instanceof $)) {
                options.filesContainer = $(options.filesContainer);
            }
        },

        _initSpecialOptions: function () {
            this._super();
            this._initFilesContainer();
            this._initTemplates();
        },

        _create: function () {
            this._super();
            this._resetFinishedDeferreds();
            if (!$.support.fileInput) {
                this._disableFileInputButton();
            }
        },

        enable: function () {
            var wasDisabled = false;
            if (this.options.disabled) {
                wasDisabled = true;
            }
            this._super();
            if (wasDisabled) {
                this.element.find('input, button').prop('disabled', false);
                this._enableFileInputButton();
            }
        },

        disable: function () {
            if (!this.options.disabled) {
                this.element.find('input, button').prop('disabled', true);
                this._disableFileInputButton();
            }
            this._super();
        }

    });

}));

################################################################################
