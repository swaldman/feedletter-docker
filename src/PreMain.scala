import com.mchange.feedletter.{UserUntemplates,Main}
import com.mchange.feedletter.style.{AllUntemplates,StyleMain}

object PreMain:
  def main( args : Array[String] ) : Unit =
    AllUntemplates.add( UserUntemplates )
    val styleExec =
      sys.env.get("FEEDLETTER_STYLE") match
        case Some( s ) => s.toBoolean
        case None      => false
    if styleExec then StyleMain.main(args) else Main.main(args)

