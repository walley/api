function init_menu()
{

  $(function() {
    $("#menu").menu();
  });


  $("#navmenu").click(function() {
    $("#menu").toggle();
  });


  $("#navmenu").hover(
    function() {
      $(this).stop().animate({"border-color": "red"}, "slow");
    },
    function() {
      $(this).stop().animate({"border-color": "black"}, "slow");
    }
  );

//  $("#menu").toggle(); 
  get_username();
}

function set_username()
{
  $("#username").html(username);
}

function get_username()
{
  var jqxhr;

  $.ajaxSetup({xhrFields: { withCredentials: true } });
  jqxhr= $.get("https://api.openstreetmap.social/table/username/")
  .done(function(data) {
    username = data;
    set_username();
  })
  .fail(function() {
    alert("username error");
  })
  .always(function() {
  });
}
